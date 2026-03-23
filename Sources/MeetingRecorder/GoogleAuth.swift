import AppKit
import Foundation

/// Handles Google OAuth 2.0 for desktop apps.
/// Uses a local HTTP server to catch the redirect, then exchanges the code for tokens.
final class GoogleAuth {
    private static let clientID = "983588554931-57jkfl300odr61n573o2ko20dobujldt.apps.googleusercontent.com"
    private static let workerBase = "https://keys.lightswitchlabs.ai"
    private static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"

    struct Tokens {
        let idToken: String
        let refreshToken: String?
        let email: String?
    }

    /// Run the full OAuth flow: open browser, catch redirect, exchange code.
    static func signIn(completion: @escaping (Tokens?) -> Void) {
        // Start local server to catch the OAuth redirect
        let server = LocalOAuthServer()
        guard let port = server.start() else {
            fputs("[google-auth] Failed to start local OAuth server\n", stderr)
            completion(nil)
            return
        }

        let redirectURI = "http://127.0.0.1:\(port)"

        // Build OAuth URL
        var components = URLComponents(string: authEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        let authURL = components.url!
        fputs("[google-auth] Opening browser for sign-in\n", stderr)
        NSWorkspace.shared.open(authURL)

        // Wait for the redirect with the auth code
        server.waitForCode { code in
            server.stop()

            guard let code = code else {
                fputs("[google-auth] No auth code received\n", stderr)
                completion(nil)
                return
            }

            fputs("[google-auth] Auth code received, exchanging for tokens\n", stderr)
            exchangeCode(code, redirectURI: redirectURI, completion: completion)
        }
    }

    /// Use a refresh token to get a new ID token without user interaction.
    static func refresh(refreshToken: String, completion: @escaping (Tokens?) -> Void) {
        var request = URLRequest(url: URL(string: "\(workerBase)/api/auth/refresh")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let bodyDict: [String: String] = ["refresh_token": refreshToken]
        request.httpBody = try? JSONSerialization.data(withJSONObject: bodyDict)

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let idToken = json["id_token"] as? String else {
                fputs("[google-auth] Token refresh failed: \(error?.localizedDescription ?? "unknown")\n", stderr)
                completion(nil)
                return
            }

            let tokens = Tokens(idToken: idToken, refreshToken: refreshToken, email: nil)
            completion(tokens)
        }.resume()
    }

    private static func exchangeCode(_ code: String, redirectURI: String, completion: @escaping (Tokens?) -> Void) {
        var request = URLRequest(url: URL(string: "\(workerBase)/api/auth/exchange")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let bodyDict: [String: String] = ["code": code, "redirect_uri": redirectURI]
        request.httpBody = try? JSONSerialization.data(withJSONObject: bodyDict)

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let idToken = json["id_token"] as? String else {
                fputs("[google-auth] Code exchange failed: \(error?.localizedDescription ?? "unknown")\n", stderr)
                if let data = data, let respBody = String(data: data, encoding: .utf8) {
                    fputs("[google-auth] Response: \(respBody.prefix(500))\n", stderr)
                }
                completion(nil)
                return
            }

            let refreshToken = json["refresh_token"] as? String
            fputs("[google-auth] Tokens received (refresh: \(refreshToken != nil ? "yes" : "no"))\n", stderr)

            let tokens = Tokens(idToken: idToken, refreshToken: refreshToken, email: nil)
            completion(tokens)
        }.resume()
    }
}

// MARK: - Local HTTP Server for OAuth Redirect

/// Minimal HTTP server that listens on localhost for the Google OAuth redirect.
private final class LocalOAuthServer {
    private var serverSocket: Int32 = -1
    private var port: UInt16 = 0
    private var codeCallback: ((String?) -> Void)?

    /// Start listening. Returns the port number, or nil on failure.
    func start() -> UInt16? {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else { return nil }

        var one: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // OS picks a free port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            close(serverSocket)
            return nil
        }

        // Get the assigned port
        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(serverSocket, $0, &addrLen)
            }
        }
        port = UInt16(bigEndian: boundAddr.sin_port)

        listen(serverSocket, 1)
        fputs("[oauth-server] Listening on 127.0.0.1:\(port)\n", stderr)
        return port
    }

    /// Wait for the OAuth redirect. Calls back with the auth code (or nil on error/timeout).
    func waitForCode(completion: @escaping (String?) -> Void) {
        self.codeCallback = completion

        DispatchQueue.global().async { [weak self] in
            guard let self = self, self.serverSocket >= 0 else {
                completion(nil)
                return
            }

            // Set a 120-second timeout for accept
            var timeout = timeval(tv_sec: 120, tv_usec: 0)
            setsockopt(self.serverSocket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            let clientSocket = accept(self.serverSocket, nil, nil)
            guard clientSocket >= 0 else {
                fputs("[oauth-server] Accept timed out or failed\n", stderr)
                completion(nil)
                return
            }

            // Read the HTTP request
            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(clientSocket, &buffer, buffer.count)
            guard bytesRead > 0 else {
                Darwin.close(clientSocket)
                completion(nil)
                return
            }

            let requestString = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""

            // Extract the code from the query string
            var code: String?
            if let getLine = requestString.components(separatedBy: "\r\n").first,
               let urlPart = getLine.split(separator: " ").dropFirst().first,
               let components = URLComponents(string: String(urlPart)),
               let codeParam = components.queryItems?.first(where: { $0.name == "code" }) {
                code = codeParam.value
            }

            // Send a response to the browser
            let htmlBody: String
            if code != nil {
                htmlBody = "<html><body><h2>Signed in successfully!</h2><p>You can close this tab and return to Meeting Recorder.</p></body></html>"
            } else {
                htmlBody = "<html><body><h2>Sign-in failed</h2><p>Please try again from the app.</p></body></html>"
            }

            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(htmlBody.utf8.count)\r\nConnection: close\r\n\r\n\(htmlBody)"
            _ = response.withCString { ptr in
                write(clientSocket, ptr, strlen(ptr))
            }

            Darwin.close(clientSocket)
            completion(code)
        }
    }

    func stop() {
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
    }
}
