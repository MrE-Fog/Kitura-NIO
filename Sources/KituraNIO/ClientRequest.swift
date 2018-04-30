import NIO
import NIOHTTP1
import Foundation
import NIOOpenSSL

public class ClientRequest {
    
    public var headers = [String: String]()

    public private(set) var url: String = ""

    public private(set) var method: String = "get"

    public private(set) var userName: String?

    public private(set) var password: String?

    public internal(set) var maxRedirects = 10

    public private(set) var closeConnection = false

    public private(set) var callback: Callback

    var port: Int16?

    var bodyData: Data?

    var hostName: String?

    /// Should SSL verification be enabled
    private var enableSSLVerification = false {
        didSet {
            if enableSSLVerification {
                self.sslConfig = TLSConfiguration.forClient(certificateVerification: .none)
            }
        }
    }

    var sslConfig: TLSConfiguration?

    internal var redirectCount: Int = 0

    private var sslContext: NIOOpenSSL.SSLContext?

    /// Should HTTP/2 protocol be used
    private var useHTTP2 = false

    private var path = ""

    public enum Options {
        case method(String)

        case schema(String)
  
        case hostname(String)

        case port(Int16)

        case path(String)

        case headers([String: String])

        case username(String)

        case password(String)

        case maxRedirects(Int)

        case disableSSLVerification

        case useHTTP2
    }


   convenience init(url: String, callback: @escaping Callback) {
        let options =  ClientRequest.parse(URL(string: url)!)
        self.init(options: options, callback: callback)
        self.url = url
        self.callback = callback
    }

    public func set(_ option: Options) {
        switch(option) {
        case .schema, .hostname, .port, .path, .username, .password:
            print("Must use ClientRequest.init() to set URL components")
        case .method(let method):
            self.method = method
        case .headers(let headers):
            for (key, value) in headers {
                self.headers[key] = value
            }
        case .maxRedirects(let maxRedirects):
            self.maxRedirects = maxRedirects
        case .disableSSLVerification:
            self.enableSSLVerification = true
        case .useHTTP2:
            self.useHTTP2 = true
        }
    }

    init(options: [Options], callback: @escaping Callback) {

        self.callback = callback

        var theSchema = "http://"
        var hostName = "localhost"
        var path = "/"
        var port = ""

        for option in options  {
            switch(option) {

                case .method, .headers, .maxRedirects, .disableSSLVerification, .useHTTP2:
                    // call set() for Options that do not construct the URL
                    set(option)
                case .schema(var schema):
                    if !schema.contains("://") && !schema.isEmpty {
                      schema += "://"
                    }
                    theSchema = schema
                case .hostname(let host):
                    hostName = host
                    self.hostName = host
                case .port(let thePort):
                    port = ":\(thePort)"
                    self.port = thePort
                case .path(var thePath):
                    if thePath.first != "/" {
                      thePath = "/" + thePath
                    }
                    path = thePath
                    self.path = path
                case .username(let userName):
                    self.userName = userName
                case .password(let password):
                    self.password = password
            }
        }

        // Adding support for Basic HTTP authentication
        let user = self.userName ?? ""
        let pwd = self.password ?? ""
        var authenticationClause = ""
        // If either the userName or password are non-empty, add the authenticationClause
        if (!user.isEmpty || !pwd.isEmpty) {
          authenticationClause = "\(user):\(pwd)@"
        }

        url = "\(theSchema)\(authenticationClause)\(hostName)\(port)\(path)"

    }

    public typealias Callback = (ClientResponse?) -> Void

    public class func parse(_ urlString: String) -> [ClientRequest.Options] {
        if let url = URL(string: urlString) {
            return parse(url)
        }
        return []
    }

    public class func parse(_ url: URL) -> [ClientRequest.Options] {

        var options: [ClientRequest.Options] = []

        if let scheme = url.scheme {
            options.append(.schema("\(scheme)://"))
        }
        if let host = url.host {
            options.append(.hostname(host))
        }
        var fullPath = url.path
        // query strings and parameters need to be appended here
        if let query = url.query {
            fullPath += "?"
            fullPath += query
        }
        options.append(.path(fullPath))
        if let port = url.port {
            options.append(.port(Int16(port)))
        }
        if let username = url.user {
            options.append(.username(username))
        }
        if let password = url.password {
            options.append(.password(password))
        }
        return options
    }

    public func write(from string: String) {
        if let data = string.data(using: .utf8) {
            write(from: data)
        }
    }

    public func write(from data: Data) {
        if bodyData == nil {
            bodyData = Data()
        }
        bodyData!.append(data)
        headers["Content-Length"] = "\(bodyData!.count)" //very eagerly adding
    }

    public func end(_ data: String, close: Bool = false) {
        write(from: data)
        end(close: close)
    }

    public func end(_ data: Data, close: Bool = false) {
        write(from: data)
        end(close: close)
    }

    var channel: Channel!

    var bootstrap: ClientBootstrap!

    public func end(close: Bool = false) {
        closeConnection = close

        //TODO: Handle redirection
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        if (URL(string: url)?.scheme)! == "https" {
           enableSSLVerification = true
        }

        if enableSSLVerification {
            initializeClientBootstrapWithSSL(eventLoopGroup: group)
        } else {
            initializeClientBootstrap(eventLoopGroup: group)
        }

        let hostName = URL(string: url)?.host ?? "" //TODO: what could be the failure path here
        if self.headers["Host"] == nil {
           self.headers["Host"] = hostName
        }
        self.headers["User-Agent"] = "KituraNIO"
        if closeConnection {
            self.headers["Connection"] = "close"
        }
        if self.port == nil {
            self.port = enableSSLVerification ? 443 : 80
        }
        do {
            channel = try bootstrap.connect(host: hostName, port: Int(self.port ?? 80)).wait()
        } catch {
            callback(nil)
            return //we must ideally throw from here, but alas!
        }
        var request = HTTPRequestHead(version: HTTPVersion(major: 1, minor:1), method: HTTPMethod.method(from: self.method), uri: self.path)
        request.headers = HTTPHeaders.from(dictionary: self.headers)
        channel.write(NIOAny(HTTPClientRequestPart.head(request)), promise: nil)
        if let bodyData = bodyData {
            let buffer = BufferList()
            buffer.append(data: bodyData)
            channel.write(NIOAny(HTTPClientRequestPart.body(.byteBuffer(buffer.byteBuffer))), promise: nil)
        }
        try! channel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil))).wait()
    }

    private func initializeClientBootstrapWithSSL(eventLoopGroup: EventLoopGroup) {
        if let sslConfig = self.sslConfig {
            sslContext = try! SSLContext(configuration: sslConfig)
        }
        bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelInitializer { channel in
                channel.pipeline.add(handler: try! OpenSSLClientHandler(context: self.sslContext!)).then {
                    channel.pipeline.addHTTPClientHandlers().then {
                        channel.pipeline.add(handler: HTTPClientHandler(request: self))
                    }
                }
            }
    }

    private func initializeClientBootstrap(eventLoopGroup: EventLoopGroup) {
        bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers().then {
                    channel.pipeline.add(handler: HTTPClientHandler(request: self))
                }
            }
    }
}

extension HTTPHeaders {
    static func from(dictionary: [String: String]) -> HTTPHeaders {
        var headers = HTTPHeaders()
        for (key, value) in dictionary {
            headers.add(name: key, value: value)
        }
        return headers
    }
}

extension HTTPMethod {
    static func method(from method: String) -> HTTPMethod {
        let methodUpperCase = method.uppercased()
        switch methodUpperCase {
        case "GET":
            return .GET
        case "PUT":
            return .PUT
        case "ACL":
            return .ACL
        case "HEAD":
            return .HEAD
        case "POST":
            return .POST
        case "COPY":
            return .COPY
        case "LOCK":
            return .LOCK
        case "MOVE":
            return .MOVE
        case "BIND":
            return .BIND
        case "LINK":
            return .LINK
        case "PATCH":
            return .PATCH
        case "TRACE":
            return .TRACE
        case "MKCOL":
            return .MKCOL
        case "MERGE":
            return .MERGE
        case "PURGE":
            return .PURGE
        case "NOTIFY":
            return .NOTIFY
        case "SEARCH":
            return .SEARCH
        case "UNLOCK":
            return .UNLOCK
        case "REBIND":
            return .REBIND
        case "UNBIND":
            return .UNBIND
        case "REPORT":
            return .REPORT
        case "DELETE":
            return .DELETE
        case "UNLINK":
            return .UNLINK
        case "CONNECT":
            return .CONNECT
        case "MSEARCH":
            return .MSEARCH
        case "OPTIONS":
            return .OPTIONS
        case "PROPFIND":
            return .PROPFIND
        case "CHECKOUT":
            return .CHECKOUT
        case "PROPPATCH":
            return .PROPPATCH
        case "SUBSCRIBE":
            return .SUBSCRIBE
        case "MKCALENDAR":
            return .MKCALENDAR
        case "MKACTIVITY":
            return .MKACTIVITY
        case "UNSUBSCRIBE":
            return .UNSUBSCRIBE
        default:
            return HTTPMethod.RAW(value: methodUpperCase)
        }

    }
}

public class HTTPClientHandler: ChannelInboundHandler {
   
     private var clientResponse: ClientResponse = ClientResponse()

     private let clientRequest: ClientRequest

     init(request: ClientRequest) {
         self.clientRequest = request
     }

     public typealias InboundIn = HTTPClientResponsePart

     public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
         let request = self.unwrapInboundIn(data)
         switch request {
         case .head(let header):
             clientResponse.headers = HeadersContainer.create(from: header.headers)
             clientResponse.httpVersionMajor = header.version.major
             clientResponse.httpVersionMinor = header.version.minor
             clientResponse.statusCode = HTTPStatusCode(rawValue: Int(header.status.code))!
         case .body(var buffer):
             if clientResponse.buffer == nil {
                 clientResponse.buffer = BufferList(with: buffer)
             } else {
                 clientResponse.buffer!.byteBuffer.write(buffer: &buffer)
             }
         case .end(_):
            if clientResponse.statusCode == .movedTemporarily || clientResponse.statusCode == .movedPermanently {
                self.clientRequest.redirectCount += 1
                if self.clientRequest.redirectCount < self.clientRequest.maxRedirects {
                    guard let url = clientResponse.headers["Location"]?.first else { fatalError("Redirected but no Location header") }
                    if url.starts(with: "/") {
                        let scheme = URL(string: clientRequest.url)?.scheme
                        let request = ClientRequest(options: [.schema(scheme!), .hostname(clientRequest.hostName!), .port(clientRequest.port!), .path(url)], callback: clientRequest.callback)
                        request.maxRedirects = self.clientRequest.maxRedirects - 1
                        request.end()
                    } else {
                        let request = ClientRequest(url: url, callback: clientRequest.callback)
                        request.maxRedirects = self.clientRequest.maxRedirects - 1
                        request.end()
                    }
                } else {
                    clientRequest.callback(clientResponse)
                }
            } else {
                clientRequest.callback(clientResponse)
            }
            clientRequest.channel.close().whenFailure { error in
                //TODO: log unexpected error
            }
         }
     }
}

