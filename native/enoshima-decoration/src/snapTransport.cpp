#include "snapTransport.hpp"

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

using namespace std::chrono_literals;

CSnapTransport::CSnapTransport() : m_worker([this] { workerLoop(); }) {}

CSnapTransport::~CSnapTransport() {
    {
        std::lock_guard lock(m_mutex);
        m_stopping = true;
        m_previews.clear();
        m_terminal.clear();
    }
    m_wakeup.notify_all();
    if (m_worker.joinable())
        m_worker.join();
}

void CSnapTransport::enqueuePreview(std::string key, std::string payload) {
    {
        std::lock_guard lock(m_mutex);
        if (m_stopping)
            return;
        auto request = SRequest{.key = key, .payload = std::move(payload), .terminal = false};
        m_previews.insert_or_assign(key, std::move(request));
    }
    m_wakeup.notify_one();
}

void CSnapTransport::enqueueTerminal(std::string key, std::string payload, bool preserveLatestPreview) {
    {
        std::lock_guard lock(m_mutex);
        if (m_stopping)
            return;

        const auto preview = m_previews.find(key);
        if (preview != m_previews.end()) {
            if (preserveLatestPreview) {
                preview->second.terminal = true;
                m_terminal.push_back(std::move(preview->second));
            }
            m_previews.erase(preview);
        }

        if (m_terminal.size() >= 64)
            m_terminal.pop_front();
        m_terminal.push_back(SRequest{.key = std::move(key), .payload = std::move(payload), .terminal = true});
    }
    m_wakeup.notify_one();
}

void CSnapTransport::workerLoop() {
    auto failureBackoff = 20ms;

    while (true) {
        SRequest request;
        {
            std::unique_lock lock(m_mutex);
            m_wakeup.wait(lock, [this] { return m_stopping || !m_terminal.empty() || !m_previews.empty(); });
            if (m_stopping && m_terminal.empty() && m_previews.empty())
                return;

            if (!m_terminal.empty()) {
                request = std::move(m_terminal.front());
                m_terminal.pop_front();
            } else {
                auto preview = m_previews.begin();
                request      = std::move(preview->second);
                m_previews.erase(preview);
            }
        }

        if (sendRequest(request.payload)) {
            failureBackoff = 20ms;
            continue;
        }

        std::unique_lock lock(m_mutex);
        m_wakeup.wait_for(lock, failureBackoff, [this] { return m_stopping; });
        if (m_stopping)
            return;
        if (request.terminal)
            m_terminal.push_front(std::move(request));
        failureBackoff = std::min(failureBackoff * 2, 1000ms);
    }
}

bool CSnapTransport::sendRequest(const std::string& payload) const {
    const auto runtime = std::getenv("XDG_RUNTIME_DIR");
    if (!runtime || runtime[0] != '/')
        return false;

    const auto socketPath = std::string(runtime) + "/enoshima/windowd.sock";
    sockaddr_un endpoint  = {};
    endpoint.sun_family   = AF_UNIX;
    if (socketPath.size() >= sizeof(endpoint.sun_path))
        return false;
    std::memcpy(endpoint.sun_path, socketPath.c_str(), socketPath.size() + 1);

    const int descriptor = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    if (descriptor < 0)
        return false;

    timeval timeout = {.tv_sec = 0, .tv_usec = 50000};
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    if (connect(descriptor, reinterpret_cast<sockaddr*>(&endpoint), sizeof(endpoint)) < 0) {
        close(descriptor);
        return false;
    }

    const auto sent = send(descriptor, payload.data(), payload.size(), MSG_NOSIGNAL);
    char       response[512];
    const auto received = sent == static_cast<ssize_t>(payload.size()) ? recv(descriptor, response, sizeof(response), 0) : -1;
    close(descriptor);
    return sent == static_cast<ssize_t>(payload.size()) && received > 0;
}
