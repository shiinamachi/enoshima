#pragma once

#include <condition_variable>
#include <cstddef>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>

class CSnapTransport {
  public:
    CSnapTransport();
    ~CSnapTransport();

    CSnapTransport(const CSnapTransport&)            = delete;
    CSnapTransport& operator=(const CSnapTransport&) = delete;

    void enqueuePreview(std::string key, std::string payload);
    void enqueueTerminal(std::string key, std::string payload, bool preserveLatestPreview);

  private:
    struct SRequest {
        std::string key;
        std::string payload;
    };

    void workerLoop();
    bool sendRequest(const std::string& payload) const;

    std::mutex                                m_mutex;
    std::condition_variable                   m_wakeup;
    std::unordered_map<std::string, SRequest> m_previews;
    std::deque<SRequest>                      m_terminal;
    std::thread                               m_worker;
    bool                                      m_stopping = false;
};
