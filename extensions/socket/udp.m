#import <LuaSkin/LuaSkin.h>
#import <CocoaAsyncSocket/GCDAsyncUdpSocket.h>

// Definitions
@interface HSAsyncUdpSocket : GCDAsyncUdpSocket
@property int readCallback;
@property int connectCallback;
@property NSTimeInterval timeout;
@end

// Userdata for hs.socket.udp objects
#define getUserData(L, idx) (__bridge HSAsyncUdpSocket *)((asyncUdpSocketUserData *)lua_touserdata(L, idx))->asyncUdpSocket;

static const char *USERDATA_TAG = "hs.socket.udp";

typedef struct _asyncUdpSocketUserData {
    int selfRef;
    void *asyncUdpSocket;
} asyncUdpSocketUserData;

// These constants are used to set GCDAsyncUdpSocket's built-in userData to distinguish socket types.
// Foreign client sockets (from netcat for example) connecting to our listening sockets are of type
// GCDAsyncUdpSocket and attempting to place our subclass's new properties on them will fail
static const NSString *DEFAULT = @"DEFAULT";
static const NSString *SERVER = @"SERVER";
static const NSString *CLIENT = @"CLIENT";

// Callback on data reads
static int refTable = LUA_NOREF;

static void readCallback(HSAsyncUdpSocket *asyncUdpSocket, NSData *data, NSData *address) {
    LuaSkin *skin = [LuaSkin shared];
    NSString *utf8Data = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

    if (!asyncUdpSocket.readCallback || asyncUdpSocket.readCallback == LUA_NOREF) {
        [skin logError:@"No callback defined!"];
    } else {
        [skin pushLuaRef:refTable ref:asyncUdpSocket.readCallback];
        [skin pushNSObject: utf8Data];
        [skin pushNSObject: address];

        if (![skin protectedCallAndTraceback:2 nresults:0]) {
            const char *errorMsg = lua_tostring(skin.L, -1);
            [skin logError:[NSString stringWithFormat:@"hs.socket.udp read callback error: %s", errorMsg]];
        }
    }
}

// Delegate implementation
@implementation HSAsyncUdpSocket

- (id)init {
    self.readCallback = LUA_NOREF;
    self.connectCallback = LUA_NOREF;
    self.timeout = -1;
    return [super initWithDelegate:self delegateQueue:dispatch_get_main_queue()];
}

- (void)udpSocket:(HSAsyncUdpSocket *)sock didConnectToAddress:(NSData *)address {
    LuaSkin *skin = [LuaSkin shared];
    [skin logInfo:@"UDP socket connected"];
    sock.userData = DEFAULT;

    if (sock.connectCallback != LUA_NOREF) {
        [skin pushLuaRef:refTable ref:sock.connectCallback];
        sock.connectCallback = [skin luaUnref:refTable ref:sock.connectCallback];
        if (![skin protectedCallAndTraceback:0 nresults:0]) {
            const char *errorMsg = lua_tostring(skin.L, -1);
            [skin logError:[NSString stringWithFormat:@"hs.socket.udp connect callback error: %s", errorMsg]];
        }
    }
}

- (void)udpSocket:(HSAsyncUdpSocket *)sock didNotConnect:(NSError *)error {
    [[LuaSkin shared] logWarn:@"UDP socket did not connect"];
}

- (void)udpSocket:(HSAsyncUdpSocket *)sock didSendDataWithTag:(long)tag {
    [[LuaSkin shared] logInfo:@"Data written to socket"];
}

- (void)udpSocket:(HSAsyncUdpSocket *)sock didNotSendDataWithTag:(long)tag dueToError:(NSError *)error {
    [[LuaSkin shared] logWarn:@"Data not written to socket"];
}

- (void)udpSocket:(HSAsyncUdpSocket *)sock didReceiveData:(NSData *)data fromAddress:(NSData *)address withFilterContext:(id)filterContext {
    [[LuaSkin shared] logInfo:@"Data received on socket"];

    readCallback(self, data, address);
}

- (void)udpSocketDidClose:(HSAsyncUdpSocket *)sock withError:(NSError *)error {
    [[LuaSkin shared] logInfo:@"UDP socket closed"];
}

@end


// Establish connection
static void connectSocket(HSAsyncUdpSocket *asyncUdpSocket, NSString *host, UInt16 port) {
    NSError *err;
    if (![asyncUdpSocket connectToHost:host onPort:port error:&err]) {
        [[LuaSkin shared] logError:[NSString stringWithFormat:@"Unable to connect: %@", err]];
    }
}

// Establish listening port
static void listenSocket(HSAsyncUdpSocket *asyncUdpSocket, UInt16 port) {
    NSError *err;
    if (![asyncUdpSocket bindToPort:port error:&err]) {
        [[LuaSkin shared] logError:[NSString stringWithFormat:@"Unable to bind port: %@", err]];
    } else {
        asyncUdpSocket.userData = SERVER;
    }
}

/// hs.socket.udp.new([fn]) -> hs.socket.udp object
/// Constructor
/// Creates an unconnected asynchronous UDP socket object
///
/// Parameters:
///  * fn - An optional callback function to process data on reads. Can also be set with the [`setCallback`](#setCallback) method
///
/// Returns:
///  * An [`hs.socket.udp`](#new) object
///
static int socketudp_new(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared];
    [skin checkArgs:LS_TFUNCTION|LS_TOPTIONAL, LS_TBREAK];

    HSAsyncUdpSocket *asyncUdpSocket = [[HSAsyncUdpSocket alloc] init];

    if (lua_type(L, 1) == LUA_TFUNCTION) {
        lua_pushvalue(L, 1);
        asyncUdpSocket.readCallback = [skin luaRef:refTable];
    }

    lua_getglobal(skin.L, "hs"); lua_getfield(skin.L, -1, "socket"); lua_getfield(skin.L, -1, "timeout");
    asyncUdpSocket.timeout = lua_tonumber(skin.L, -1);

    // Create the userdata object
    asyncUdpSocketUserData *userData = lua_newuserdata(L, sizeof(asyncUdpSocketUserData));
    memset(userData, 0, sizeof(asyncUdpSocketUserData));
    userData->asyncUdpSocket = (__bridge_retained void*)asyncUdpSocket;

    luaL_getmetatable(L, USERDATA_TAG);
    lua_setmetatable(L, -2);
    return 1;
}

/// hs.socket.udp.parseAddress(sockaddr) -> table
/// Function
/// Parses a binary sockaddr address into a readable table
///
/// Parameters:
///  * sockaddr - A binary address descriptor, usually obtained in the read callback or from the [`info`](#info) method
///
/// Returns:
///  * A table describing the address with the following keys:
///   * host - A string containing the host IP
///   * port - A number containing the port
///   * addressFamily - A number containing the address family
///
/// Notes:
///  * Some address family definitions from `<sys/socket.h>`:
///
/// address family | number | description 
/// :--- | :--- | :--- 
/// AF_UNSPEC | 0 | unspecified 
/// AF_UNIX | 1 | local to host (pipes) 
/// AF_LOCAL | AF_UNIX | backward compatibility 
/// AF_INET | 2 | internetwork: UDP, TCP, etc. 
/// AF_NS | 6 | XEROX NS protocols
/// AF_CCITT | 10 | CCITT protocols, X.25 etc 
/// AF_APPLETALK | 16 | Apple Talk
/// AF_ROUTE | 17 | Internal Routing Protocol 
/// AF_LINK | 18 | Link layer interface
/// AF_INET6 | 30 | IPv6 
///
static int socketudp_parseAddress(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared];
    [skin checkArgs:LS_TSTRING, LS_TBREAK];
    NSString *addressStr = [skin toNSObjectAtIndex:1];
    NSData *address = [addressStr dataUsingEncoding:NSUTF8StringEncoding];

    NSString *host; UInt16 port; int addressFamily;
    [HSAsyncUdpSocket getHost:&host port:&port family:&addressFamily fromAddress:address];

    NSDictionary *addressDict = @{
        @"host": host,
        @"port": @(port),
        @"addressFamily": @(addressFamily),
    };

    [skin pushNSObject:addressDict];
    return 1;
}

/// hs.socket.udp:connect(host, port[, fn]) -> self
/// Method
/// Connects an unconnected [`hs.socket.udp`](#new) instance
/// By design, UDP is a connectionless protocol, and connecting is not needed
///
/// Parameters:
///  * host - A string containing the hostname or IP address
///  * port - A port number [1-65535]
///  * fn - An optional callback function to execute after establishing the connection. Takes no parameters
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object
///
/// Notes:
/// * Choosing to connect to a specific host/port has the following effect:
/// * - You will only be able to send data to the connected host/port
/// * - You will only be able to receive data from the connected host/port
/// * - You will receive ICMP messages that come from the connected host/port, such as "connection refused"
///
/// * The actual process of connecting a UDP socket does not result in any communication on the socket
/// * It simply changes the internal state of the socket
///
/// * You cannot bind a socket after it has been connected
/// * You can only connect a socket once
///
static int socketudp_connect(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TNUMBER, LS_TFUNCTION|LS_TOPTIONAL, LS_TBREAK];
    HSAsyncUdpSocket* asyncUdpSocket = getUserData(L, 1);
    NSString *theHost = [skin toNSObjectAtIndex:2];
    UInt16 thePort = [[skin toNSObjectAtIndex:3] unsignedShortValue];

    if (lua_type(L, 4) == LUA_TFUNCTION) {
        lua_pushvalue(L, 4);
        asyncUdpSocket.connectCallback = [skin luaRef:refTable];
    } else {
        asyncUdpSocket.connectCallback = LUA_NOREF;
    }

    connectSocket(asyncUdpSocket, theHost, thePort);

    lua_pushvalue(L, 1);
    return 1;
}

/// hs.socket.udp:listen(port) -> self
/// Method
/// Binds an unconnected [`hs.socket.udp`](#new) instance to a port for listening
///
/// Parameters:
///  * port - A port number [0-65535]. Ports [1-1023] are privileged. Port 0 allows the OS to select any available port
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object
///
static int socketudp_listen(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER, LS_TBREAK];
    HSAsyncUdpSocket* asyncUdpSocket = getUserData(L, 1);
    UInt16 thePort = [[skin toNSObjectAtIndex:2] unsignedShortValue];

    listenSocket(asyncUdpSocket, thePort);

    lua_pushvalue(L, 1);
    return 1;
}

/// hs.socket.udp:close() -> self
/// Method
/// Immediately closes the underlying socket, freeing the [`hs.socket.udp`](#new) for reuse. Any pending send operations are discarded
///
/// Parameters:
///  * None
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object
///
static int socketudp_close(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSAsyncUdpSocket* asyncUdpSocket = getUserData(L, 1);

    [asyncUdpSocket close];

    lua_pushvalue(L, 1);
    return 1;
}

/// hs.socket.udp:receive([fn]) -> self
/// Method
/// Read packets from the socket continuously as they arrive
///
/// Parameters:
///  * fn - Optionally supply the read callback here
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object
///
/// Notes:
///  * There are two modes of operation for receiving packets: one-at-a-time & continuous.
///
///  * In one-at-a-time mode, you call receiveOnce everytime your delegate is ready to process an incoming UDP packet
///  * Receiving packets one-at-a-time may be better suited for implementing certain state machine code where your state machine may not always be ready to process incoming packets
///
///  * In continuous mode, the delegate is invoked immediately everytime incoming udp packets are received
///  * Receiving packets continuously is better suited to real-time streaming applications
///
///  * You may switch back and forth between one-at-a-time mode and continuous mode
///  * If the socket is currently in one-at-a-time mode, calling this method will switch it to continuous mode
///
static int socketudp_receive(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION|LS_TOPTIONAL, LS_TBREAK];
    HSAsyncUdpSocket* asyncUdpSocket = getUserData(L, 1);

    if (lua_type(L, 2) == LUA_TFUNCTION) {
        asyncUdpSocket.readCallback = [skin luaUnref:refTable ref:asyncUdpSocket.readCallback];
        lua_pushvalue(L, 2);
        asyncUdpSocket.readCallback = [skin luaRef:refTable];
    }

    NSError *err;
    if (![asyncUdpSocket beginReceiving:&err]) {
        [[LuaSkin shared] logError:[NSString stringWithFormat:@"Unable to read packets: %@", err]];
    }

    lua_pushvalue(L, 1);
    return 1;
}

/// hs.socket.udp:pause() -> self
/// Method
/// Suspends reading of packets from the socket. Call the [`receive`](#receive) method to resume
///
/// Parameters:
///  * None
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object
///
static int socketudp_pause(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSAsyncUdpSocket* asyncUdpSocket = getUserData(L, 1);
    [asyncUdpSocket pauseReceiving];

    lua_pushvalue(L, 1);
    return 1;
}

/// hs.socket.udp:receiveOne([fn]) -> self
/// Method
/// Read a single packet from the socket
///
/// Parameters:
///  * fn - Optionally supply the read callback here
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object
///
/// Notes:
///  * There are two modes of operation for receiving packets: one-at-a-time & continuous.
///
///  * In one-at-a-time mode, you call receiveOnce everytime your delegate is ready to process an incoming UDP packet
///  * Receiving packets one-at-a-time may be better suited for implementing certain state machine code where your state machine may not always be ready to process incoming packets
///
///  * In continuous mode, the delegate is invoked immediately everytime incoming udp packets are received
///  * Receiving packets continuously is better suited to real-time streaming applications
///
///  * You may switch back and forth between one-at-a-time mode and continuous mode
///  * If the socket is currently in continuous mode, calling this method will switch it to one-at-a-time mode
///
static int socketudp_receiveOne(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION|LS_TOPTIONAL, LS_TBREAK];
    HSAsyncUdpSocket* asyncUdpSocket = getUserData(L, 1);

    if (lua_type(L, 2) == LUA_TFUNCTION) {
        asyncUdpSocket.readCallback = [skin luaUnref:refTable ref:asyncUdpSocket.readCallback];
        lua_pushvalue(L, 2);
        asyncUdpSocket.readCallback = [skin luaRef:refTable];
    }

    NSError *err;
    if (![asyncUdpSocket receiveOnce:&err]) {
        [[LuaSkin shared] logError:[NSString stringWithFormat:@"Unable to read packet: %@", err]];
    }

    lua_pushvalue(L, 1);
    return 1;
}

/// hs.socket.udp:send(message, host, port[, tag]) -> self
/// Method
/// Send a packet to the destination socket
///
/// Parameters:
///  * message - A string containing data to be sent on the socket
///  * host - A string containing the hostname or IP address
///  * port - A port number [1-65535]
///  * tag - An optional integer to assist with labeling writes
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object
///
/// Notes:
///  * For non-connected sockets, the remote destination is specified for each packet
///  * If the socket has been explicitly connected with [`connect`](#connect), only the message parameter and an optional tag can be supplied
///  * Recall that connecting is optional for a UDP socket
///  * For connected sockets, data can only be sent to the connected address
///
static int socketudp_send(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TANY|LS_TOPTIONAL, LS_TANY|LS_TOPTIONAL, LS_TANY|LS_TOPTIONAL, LS_TBREAK];
    HSAsyncUdpSocket* asyncUdpSocket = getUserData(L, 1);
    NSString *message = [skin toNSObjectAtIndex:2];
    long tag = -1;

    if (asyncUdpSocket.isConnected) {
        [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TNUMBER|LS_TOPTIONAL, LS_TBREAK];
        if (lua_type(L, 3) == LUA_TNUMBER) tag = lua_tointeger(L, 3);

        [asyncUdpSocket sendData:[message dataUsingEncoding:NSUTF8StringEncoding]
                     withTimeout:asyncUdpSocket.timeout
                             tag:tag];
    } else {
        [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TSTRING, LS_TNUMBER, LS_TNUMBER|LS_TOPTIONAL, LS_TBREAK];
        NSString *theHost = [skin toNSObjectAtIndex:3];
        UInt16 thePort = [[skin toNSObjectAtIndex:4] unsignedShortValue];
        if (lua_type(L, 5) == LUA_TNUMBER) tag = lua_tointeger(L, 5);

        [asyncUdpSocket sendData:[message dataUsingEncoding:NSUTF8StringEncoding]
                          toHost:theHost
                            port:thePort
                     withTimeout:asyncUdpSocket.timeout
                             tag:tag];
    }

    lua_pushvalue(L, 1);
    return 1;
}

/// hs.socket.udp:enableBroadcast(flag) -> self
/// Method
/// Enables broadcasting on the underlying socket
///
/// Parameters:
///  * flag - A boolean: `true` to enable broadcasting, `false` to disable it
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object
///
/// Notes:
///  * By default, the underlying socket in the OS will not allow you to send broadcast messages
///  * In order to send broadcast messages, you need to enable this functionality in the socket
///
///  * A broadcast is a UDP message to addresses like "192.168.255.255" or "255.255.255.255" that is delivered to every host on the network.
///  * The reason this is generally disabled by default (by the OS) is to prevent accidental broadcast messages from flooding the network.
///
static int socketudp_enableBroadcast(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN, LS_TBREAK];
    HSAsyncUdpSocket* asyncUdpSocket = getUserData(L, 1);
    BOOL broadcastFlag = lua_toboolean(L, 2);

    NSError *err;
    if (![asyncUdpSocket enableBroadcast:broadcastFlag error:&err]) {
        [[LuaSkin shared] logError:[NSString stringWithFormat:@"Unable to enable broadcasting: %@", err]];
    }

    lua_pushvalue(L, 1);
    return 1;
}

/// hs.socket.udp:preferIPversion([version]) -> self
/// Method
/// Sets the preferred IP version: IPv4, IPv6, or neutral (first to resolve)
///
/// Parameters:
///  * version - An optional number containing the preferred IP version (4 or 6). If omitted, sets the default neutral behavior
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object
///
/// Notes:
///  * For operations that require DNS resolution, GCDAsyncUdpSocket supports both IPv4 and IPv6
///  * If a DNS lookup returns only IPv4 results, GCDAsyncUdpSocket will automatically use IPv4
///  * If a DNS lookup returns only IPv6 results, GCDAsyncUdpSocket will automatically use IPv6
///  * If a DNS lookup returns both IPv4 and IPv6 results, then the protocol used depends on the configured preference
///  * If IPv4 is preferred, then IPv4 is used
///  * If IPv6 is preferred, then IPv6 is used
///  * If neutral, then the first IP version in the resolved array will be used
///
static int socketudp_preferIPversion(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER|LS_TOPTIONAL, LS_TBREAK];
    HSAsyncUdpSocket* asyncUdpSocket = getUserData(L, 1);

    if (lua_type(L, 2) == LUA_TNUMBER && lua_tointeger(L, 2) == 4) {
        [asyncUdpSocket setPreferIPv4];
    } else if (lua_type(L, 2) == LUA_TNUMBER && lua_tointeger(L, 2) == 6) {
        [asyncUdpSocket setPreferIPv6];
    } else {
        [asyncUdpSocket setIPVersionNeutral];
    }

    lua_pushvalue(L, 1);
    return 1;
}

/// hs.socket.udp:setCallback([fn]) -> self
/// Method
/// Sets the read callback for the [`hs.socket.udp`](#new) instance. **Required** for working with read data
/// The callback has 2 parameters: the data read from the socket and the sending address. The sending address is a binary `sockaddr` structure that can be read with the [`parseAddress`](#parseAddress) function
///
/// Parameters:
///  * fn - An optional callback function to process data read from the socket. A `nil` argument or nothing clears the callback
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object
///
static int socketudp_setCallback(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION|LS_TNIL|LS_TOPTIONAL, LS_TBREAK];
    HSAsyncUdpSocket* asyncUdpSocket = getUserData(L, 1);

    asyncUdpSocket.readCallback = [skin luaUnref:refTable ref:asyncUdpSocket.readCallback];

    if (lua_type(L, 2) == LUA_TFUNCTION) {
        lua_pushvalue(L, 2);
        asyncUdpSocket.readCallback = [skin luaRef:refTable];
    } else {
        asyncUdpSocket.readCallback = LUA_NOREF;
    }

    lua_pushvalue(L, 1);
    return 1;
}

/// hs.socket.udp:setTimeout(timeout) -> self
/// Method
/// Sets the timeout for the socket operations. If the timeout value is negative, the operations will not use a timeout
///
/// Parameters:
///  * timeout - A number containing the timeout duration, in seconds
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object
///
static int socketudp_setTimeout(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER, LS_TBREAK];
    HSAsyncUdpSocket* asyncUdpSocket = getUserData(L, 1);
    NSTimeInterval timeout = lua_tonumber(L, 2);
    asyncUdpSocket.timeout = timeout;

    lua_pushvalue(L, 1);
    return 1;
}

/// hs.socket.udp:connected() -> bool
/// Method
/// Returns the connection status of the [`hs.socket.udp`](#new) instance
///
/// Parameters:
///  * None
///
/// Returns:
///  * `true` if connected, otherwise `false`
///
static int socketudp_connected(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSAsyncUdpSocket* asyncUdpSocket = getUserData(L, 1);

    lua_pushboolean(L, asyncUdpSocket.isConnected);
    return 1;
}

/// hs.socket.udp:info() -> table
/// Method
/// Returns information on the [`hs.socket.udp`](#new) instance
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing the following keys:
///   * connectedAddress - `string` (`sockaddr` struct)
///   * connectedHost - `string`
///   * connectedPort - `number`
///   * isClosed - `boolean`
///   * isConnected - `boolean`
///   * isIPv4 - `boolean`
///   * isIPv4Enabled - `boolean`
///   * isIPv4Preferred - `boolean`
///   * isIPv6 - `boolean`
///   * isIPv6Enabled - `boolean`
///   * isIPv6Preferred - `boolean`
///   * isIPVersionNeutral - `boolean`
///   * localAddress - `string` (`sockaddr` struct)
///   * localAddress_IPv4 - `string` (`sockaddr` struct)
///   * localAddress_IPv6 - `string` (`sockaddr` struct)
///   * localHost - `string`
///   * localHost_IPv4 - `string`
///   * localHost_IPv6 - `string`
///   * localPort - `number`
///   * localPort_IPv4 - `number`
///   * localPort_IPv6 - `number`
///   * maxReceiveIPv4BufferSize - `number`
///   * maxReceiveIPv6BufferSize - `number`
///   * timeout - `number`
///   * userData - `string`
///
static int socketudp_info(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSAsyncUdpSocket* asyncUdpSocket = getUserData(L, 1);

    NSDictionary *info = @{
        @"connectedAddress" : asyncUdpSocket.connectedAddress ?: @"",
        @"connectedHost" : asyncUdpSocket.connectedHost ?: @"",
        @"connectedPort" : @(asyncUdpSocket.connectedPort),
        @"isClosed": @(asyncUdpSocket.isClosed),
        @"isConnected": @(asyncUdpSocket.isConnected),
        @"isIPv4": @(asyncUdpSocket.isIPv4),
        @"isIPv4Enabled": @(asyncUdpSocket.isIPv4Enabled),
        @"isIPv4Preferred": @(asyncUdpSocket.isIPv4Preferred),
        @"isIPv6": @(asyncUdpSocket.isIPv6),
        @"isIPv6Enabled": @(asyncUdpSocket.isIPv6Enabled),
        @"isIPv6Preferred": @(asyncUdpSocket.isIPv6Preferred),
        @"isIPVersionNeutral": @(asyncUdpSocket.isIPVersionNeutral),
        @"localAddress": asyncUdpSocket.localAddress ?: @"",
        @"localAddress_IPv4": asyncUdpSocket.localAddress_IPv4 ?: @"",
        @"localAddress_IPv6": asyncUdpSocket.localAddress_IPv6 ?: @"",
        @"localHost": asyncUdpSocket.localHost ?: @"",
        @"localHost_IPv4": asyncUdpSocket.localHost_IPv4 ?: @"",
        @"localHost_IPv6": asyncUdpSocket.localHost_IPv6 ?: @"",
        @"localPort" : @(asyncUdpSocket.localPort),
        @"localPort_IPv4" : @(asyncUdpSocket.localPort_IPv4),
        @"localPort_IPv6" : @(asyncUdpSocket.localPort_IPv6),
        @"maxReceiveIPv4BufferSize" : @(asyncUdpSocket.maxReceiveIPv4BufferSize),
        @"maxReceiveIPv6BufferSize" : @(asyncUdpSocket.maxReceiveIPv6BufferSize),
        @"timeout": @(asyncUdpSocket.timeout),
        @"userData" : asyncUdpSocket.userData ?: @"",
    };

    [skin pushNSObject:info];
    return 1;
}


static int socketudp_objectGC(lua_State *L) {
    asyncUdpSocketUserData *userData = lua_touserdata(L, 1);
    HSAsyncUdpSocket* asyncUdpSocket = (__bridge_transfer HSAsyncUdpSocket *)userData->asyncUdpSocket;
    userData->asyncUdpSocket = nil;

    [asyncUdpSocket close];
    [asyncUdpSocket setDelegate:nil delegateQueue:NULL];
    asyncUdpSocket.readCallback = [[LuaSkin shared] luaUnref:refTable ref:asyncUdpSocket.readCallback];
    asyncUdpSocket = nil;

    return 0;
}

static int userdata_tostring(lua_State* L) {
    HSAsyncUdpSocket* asyncUdpSocket = getUserData(L, 1);

    BOOL isServer = (asyncUdpSocket.userData == SERVER) ? true : false;
    NSString *theHost = isServer ? asyncUdpSocket.localHost : asyncUdpSocket.connectedHost;
    uint16_t thePort = isServer ? asyncUdpSocket.localPort : asyncUdpSocket.connectedPort;

    lua_pushstring(L, [[NSString stringWithFormat:@"%s: %@:%hu (%p)", USERDATA_TAG, theHost, thePort, lua_topointer(L, 1)] UTF8String]);
    return 1;
}

static const luaL_Reg moduleLib[] = {
    {"new", socketudp_new},
    {"parseAddress", socketudp_parseAddress},

    {NULL, NULL} // This must end with an empty struct
};

static const luaL_Reg userdata_metaLib[] = {
    {"connect", socketudp_connect},
    {"listen", socketudp_listen},
    {"close", socketudp_close},
    {"receive", socketudp_receive},
    {"read", socketudp_receive},
    {"pause", socketudp_pause},
    {"receiveOne", socketudp_receiveOne},
    {"readOne", socketudp_receiveOne},
    {"send", socketudp_send},
    {"write", socketudp_send},
    {"enableBroadcast", socketudp_enableBroadcast},
    {"preferIPv6", socketudp_preferIPversion},
    {"setCallback", socketudp_setCallback},
    {"setTimeout", socketudp_setTimeout},
    {"connected", socketudp_connected},
    {"info", socketudp_info},

    {"__tostring", userdata_tostring},
    {"__gc", socketudp_objectGC},

    {NULL, NULL} // This must end with an empty struct
};

int luaopen_hs_socket_udp(lua_State *L __unused) {
    LuaSkin *skin = [LuaSkin shared];
    refTable = [skin registerLibraryWithObject:USERDATA_TAG
                                     functions:moduleLib
                                 metaFunctions:nil
                               objectFunctions:userdata_metaLib];

    return 1;
}
