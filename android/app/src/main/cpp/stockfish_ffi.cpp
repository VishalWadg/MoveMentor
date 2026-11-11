#include "stockfish_ffi.h"

#include <atomic>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <iostream>
#include <memory>
#include <mutex>
#include <streambuf>
#include <string>
#include <thread>
#include <utility>

#include "attacks.h"
#include "misc.h"
#include "position.h"
#include "tune.h"
#include "uci.h"

namespace {

class QueueInStreamBuf final : public std::streambuf {
 public:
  void push_line(const std::string& line) {
    {
      std::lock_guard<std::mutex> lock(mtx_);
      if (eof_) return;
      lines_.push_back(line + '\n');
    }
    cv_.notify_one();
  }

  void close_eof() {
    {
      std::lock_guard<std::mutex> lock(mtx_);
      eof_ = true;
    }
    cv_.notify_all();
  }

 protected:
  int_type underflow() override {
    if (gptr() < egptr()) {
      return traits_type::to_int_type(*gptr());
    }
    std::unique_lock<std::mutex> lock(mtx_);
    cv_.wait(lock, [this]() { return !lines_.empty() || eof_; });
    if (lines_.empty()) {
      return traits_type::eof();
    }
    current_ = std::move(lines_.front());
    lines_.pop_front();
    lock.unlock();

    char* begin = &current_[0];
    setg(begin, begin, begin + static_cast<std::ptrdiff_t>(current_.size()));
    return traits_type::to_int_type(*gptr());
  }

 private:
  std::mutex mtx_;
  std::condition_variable cv_;
  std::deque<std::string> lines_;
  std::string current_;
  bool eof_ = false;
};

class CallbackOutStreamBuf final : public std::streambuf {
 public:
  explicit CallbackOutStreamBuf(SfLineCallback cb) : cb_(cb) {}

  void flush_pending() {
    std::string rem;
    {
      std::lock_guard<std::mutex> lock(mtx_);
      if (!pending_.empty()) {
        rem.swap(pending_);
      }
    }
    emit(rem);
  }

 protected:
  int_type overflow(int_type ch) override {
    if (ch == traits_type::eof()) {
      return traits_type::not_eof(ch);
    }
    const char c = traits_type::to_char_type(ch);
    std::string ready;
    {
      std::lock_guard<std::mutex> lock(mtx_);
      if (c == '\n') {
        ready.swap(pending_);
      } else if (c != '\r') {
        pending_.push_back(c);
      }
    }
    if (!ready.empty()) {
      emit(ready);
    }
    return ch;
  }

  std::streamsize xsputn(const char* s, std::streamsize count) override {
    std::deque<std::string> to_emit;
    {
      std::lock_guard<std::mutex> lock(mtx_);
      for (std::streamsize i = 0; i < count; ++i) {
        const char c = s[i];
        if (c == '\n') {
          if (!pending_.empty()) {
            to_emit.push_back(std::move(pending_));
            pending_.clear();
          }
        } else if (c != '\r') {
          pending_.push_back(c);
        }
      }
    }
    for (const auto& line : to_emit) {
      emit(line);
    }
    return count;
  }

  int sync() override { return 0; }

 private:
  void emit(const std::string& line) {
    if (line.empty() || cb_ == nullptr) return;
    const size_t len = line.size();
    char* copy = static_cast<char*>(std::malloc(len + 1));
    if (copy == nullptr) return;
    std::memcpy(copy, line.data(), len);
    copy[len] = '\0';
    cb_(copy);
  }

  SfLineCallback cb_;
  std::mutex mtx_;
  std::string pending_;
};

std::once_flag g_tables_once;
std::mutex g_lifecycle_mtx;
std::mutex g_io_mtx;
std::atomic<bool> g_running{false};
std::thread g_worker;
std::shared_ptr<QueueInStreamBuf> g_in_buf;

}  // namespace

extern "C" {

int32_t sf_ffi_start(
    const char* binary_dir_hint,
    SfLineCallback on_line,
    SfExitCallback on_exit) {
  if (on_line == nullptr) {
    return -1;
  }

  std::lock_guard<std::mutex> lifecycle_lock(g_lifecycle_mtx);
  if (g_running.load()) {
    return -1;
  }
  if (g_worker.joinable()) {
    g_worker.join();
  }

  auto in_buf = std::make_shared<QueueInStreamBuf>();
  auto out_buf = std::make_shared<CallbackOutStreamBuf>(on_line);

  std::string prog_path = "stockfish";
  if (binary_dir_hint != nullptr && binary_dir_hint[0] != '\0') {
    prog_path = std::string(binary_dir_hint);
    if (prog_path.back() != '/' && prog_path.back() != '\\') {
      prog_path.push_back('/');
    }
    prog_path += "stockfish";
  }

  {
    std::lock_guard<std::mutex> io_lock(g_io_mtx);
    g_in_buf = in_buf;
  }
  g_running.store(true);

  g_worker = std::thread(
      [in_buf, out_buf, prog_path = std::move(prog_path), on_exit]() mutable {
        std::streambuf* old_cin = std::cin.rdbuf(in_buf.get());
        std::streambuf* old_cout = std::cout.rdbuf(out_buf.get());

        std::call_once(g_tables_once, []() {
          Stockfish::Attacks::init();
          Stockfish::Position::init();
        });

        char* argv_buf[2];
        std::string mutable_prog = prog_path;
        argv_buf[0] = &mutable_prog[0];
        argv_buf[1] = nullptr;

        {
          auto cli = Stockfish::CommandLine(1, argv_buf);
          auto uci = std::make_unique<Stockfish::UCIEngine>(std::move(cli));
          Stockfish::Tune::init(uci->engine_options());
          uci->loop();
        }

        out_buf->flush_pending();
        std::cout.rdbuf(old_cout);
        std::cin.rdbuf(old_cin);

        {
          std::lock_guard<std::mutex> io_lock(g_io_mtx);
          if (g_in_buf.get() == in_buf.get()) {
            g_in_buf.reset();
          }
        }
        g_running.store(false);
        if (on_exit != nullptr) {
          on_exit(0);
        }
      });

  return 0;
}

int32_t sf_ffi_send(const char* command) {
  if (command == nullptr || !g_running.load()) {
    return -1;
  }
  std::shared_ptr<QueueInStreamBuf> buf;
  {
    std::lock_guard<std::mutex> io_lock(g_io_mtx);
    buf = g_in_buf;
  }
  if (!buf) {
    return -1;
  }
  buf->push_line(std::string(command));
  return 0;
}

void sf_ffi_stop(void) {
  std::thread worker_to_join;
  {
    std::lock_guard<std::mutex> lifecycle_lock(g_lifecycle_mtx);
    std::shared_ptr<QueueInStreamBuf> buf;
    {
      std::lock_guard<std::mutex> io_lock(g_io_mtx);
      buf = g_in_buf;
    }
    if (buf) {
      buf->push_line("quit");
      buf->close_eof();
    }
    if (g_worker.joinable()) {
      worker_to_join = std::move(g_worker);
    }
  }
  if (worker_to_join.joinable()) {
    worker_to_join.join();
  }
}

void sf_ffi_free(void* ptr) { std::free(ptr); }

}  // extern "C"
