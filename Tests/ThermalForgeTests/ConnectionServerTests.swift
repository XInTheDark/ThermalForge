//
//  ConnectionServerTests.swift
//  ThermalForge
//
//  Phase 4 flood case: 8 connect-and-hang sockets fill the bounded pool; a real
//  request must still be served within ~1s, freed by the header deadline. Runs against
//  a plain bound AF_UNIX socket (ConnectionServer is decoupled from the daemon's init).
//

import Darwin
import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Connection server (Phase 4)")
struct ConnectionServerTests {

    private func setPath(_ addr: inout sockaddr_un, _ path: String) {
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, path, 104) }
        }
    }

    private func bindListener(_ path: String) -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX); setPath(&addr, path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        #expect(r == 0)
        #expect(listen(fd, 16) == 0)
        return fd
    }

    private func connectClient(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX); setPath(&addr, path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        #expect(r == 0)
        return fd
    }

    @Test("A client disconnecting before the reply does not kill the server or leak its slot")
    func disconnectedClient() throws {
        let path = "/tmp/tf-disconnect-\(UUID().uuidString).sock"
        let listenFD = bindListener(path)
        defer { close(listenFD); unlink(path) }
        let entered = DispatchSemaphore(value: 0)
        let reply = DispatchSemaphore(value: 0)
        let server = ConnectionServer(listenFD: listenFD, maxConnections: 1) { _ in
            entered.signal()
            _ = reply.wait(timeout: .now() + 3)
            return .versionResponse("served")
        }
        server.start()

        let frame = try DaemonProtocol.encodeFrame(DaemonRequest(verb: .version),
                                                   max: DaemonProtocol.maxRequestBytes)
        let abandoned = connectClient(path)
        try DaemonProtocol.writeFrame(abandoned, frame)
        let started = entered.wait(timeout: .now() + 2)
        shutdown(abandoned, SHUT_RDWR)
        close(abandoned)
        reply.signal()
        try #require(started == .success)

        // With one connection slot, this can only finish if the failed response
        // releases the abandoned connection and the server survives the write.
        let client = connectClient(path)
        defer { close(client) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        try DaemonProtocol.writeFrame(client, frame)
        reply.signal()
        let body = try DaemonProtocol.readFrame(client, max: DaemonProtocol.maxResponseBytes)
        let response = try DaemonProtocol.decode(DaemonResponse.self, from: body)
        #expect(response.version == "served")
    }

    @Test("Fan commands wait for mode acquisition beyond the old client and server deadlines")
    func slowFanCommand() throws {
        let path = "/tmp/tf-slow-command-\(UUID().uuidString).sock"
        let listenFD = bindListener(path)
        defer { close(listenFD); unlink(path) }
        let server = ConnectionServer(listenFD: listenFD) { _ in
            Thread.sleep(forTimeInterval: 5.2)
            return .ok(appliedRPM: 2317)
        }
        server.start()

        let result = try DaemonClient(socketPath: path).execute(.setRPM(2317))
        #expect(result.appliedRPM == 2317)
    }

    @Test("8 connect-and-hang sockets don't starve a real request — served within ~1s")
    func floodThenRealRequest() throws {
        let path = "/tmp/tf-conn-test.sock"
        let listenFD = bindListener(path)
        defer { close(listenFD); unlink(path) }

        let server = ConnectionServer(listenFD: listenFD, maxConnections: 8,
                                      headerDeadline: 1.0, requestDeadline: 5.0) { _ in
            .versionResponse("served")   // prove the request was actually processed
        }
        server.start()

        // Fill the pool: 8 sockets that connect and send NOTHING.
        var hangs: [Int32] = []
        for _ in 0..<8 { hangs.append(connectClient(path)) }
        defer { hangs.forEach { close($0) } }
        Thread.sleep(forTimeInterval: 0.2)   // let the acceptor take all 8

        // A real request behind the flood.
        let client = connectClient(path)
        defer { close(client) }
        let frame = try DaemonProtocol.encodeFrame(DaemonRequest(verb: .version),
                                                   max: DaemonProtocol.maxRequestBytes)
        _ = frame.withUnsafeBytes { write(client, $0.baseAddress, frame.count) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let t0 = Date()
        let body = try DaemonProtocol.readFrame(client, max: DaemonProtocol.maxResponseBytes)
        let elapsed = Date().timeIntervalSince(t0)
        let resp = try DaemonProtocol.decode(DaemonResponse.self, from: body)

        print(String(format: "FLOOD: real request served in %.3fs behind 8 connect-and-hang sockets", elapsed))
        #expect(resp.ok)
        #expect(resp.version == "served")
        #expect(elapsed < 1.3)   // freed by the ~1s header deadline, not the 5s full deadline
    }
}
