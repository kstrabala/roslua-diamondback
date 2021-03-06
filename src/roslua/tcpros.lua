
----------------------------------------------------------------------------
--  tcpros.lua - Lua implementation of TCPROS protocol
--
--  Created: Sat Jul 24 14:02:06 2010 (at Intel Research, Pittsburgh)
--  License: BSD, cf. LICENSE file of roslua
--  Copyright  2010  Tim Niemueller [www.niemueller.de]
--             2010  Carnegie Mellon University
--             2010  Intel Research Pittsburgh
----------------------------------------------------------------------------

--- TCPROS communication implementation.
-- This module contains classes that implement the TCPROS communication
-- protocol for topic as well as service communication. The user should not
-- have to use these directly, rather they are encapsulated by the
-- Publisher, Subscriber, Service, and ServiceClient classes.
-- @copyright Tim Niemueller, Carnegie Mellon University, Intel Research Pittsburgh
-- @release Released under BSD license
module("roslua.tcpros", package.seeall)

require("socket")
require("roslua.struct")
require("roslua.msg_spec")

TcpRosConnection = { payload = nil, received = false, max_receives_per_spin = 10 }

-- Timeouts are in seconds
CLIENT_TIMEOUT  = 5
SERVER_TIMEOUT  = 0

--- Constructor.
-- @param socket optionally a socket to use for communication
function TcpRosConnection:new(socket)
   local o = {}
   setmetatable(o, self)
   self.__index = self

   o.socket    = socket
   o.msg_stats = {total = 0, received = 0, sent = 0}
   o.is_client = false

   return o
end

--- Connect to given host and port.
-- @param host hostname or IP address of remote side
-- @param port port of remote side
function TcpRosConnection:connect(host, port)
   assert(not self.socket, "Socket has already been created")
   self.socket = assert(socket.connect(host, port))
   self.socket:settimeout(CLIENT_TIMEOUT)
   self.is_client = true
end

--- Close connection.
function TcpRosConnection:close()
   self.socket:close()
   self.socket = nil
end

--- Bind to random port as server.
-- This will transform the socket into a server socket allowing to
-- accept connections. The socket will bind to a ephemeral port assigned
-- by the operating system. It will set the timeout of the socket to
-- zero to avoid locks on accepting new connections.
-- @see TcpRosConnection:get_ip_port()
-- @see TcpRosConnection:accept()
function TcpRosConnection:bind()
   assert(not self.socket, "Socket has already been created")
   self.socket = assert(socket.bind("*", 0))
   self.socket:settimeout(SERVER_TIMEOUT)
end

--- Accept new connections.
-- @return array of new connections, possibly empty
function TcpRosConnection:accept()
   local conns = {}
   while true do
      local c = self.socket:accept()
      if not c then
	 break
      else
	 table.insert(conns, getmetatable(self):new(c))
      end
   end
   return conns
end

--- Get IP and port of socket.
-- @return two values, IP and port of socket
function TcpRosConnection:get_ip_port()
   return self.socket:getsockname()
end

--- Send out header.
-- @param header table with header fields to send
function TcpRosConnection:send_header(fields)
   local s = ""

   for k,v in pairs(fields) do
      local f  = k .. "=" .. v
      local fp = struct.pack("<!1i4", #f) .. f
      s = s .. fp
   end

   self.socket:send(struct.pack("<!1i4", #s) .. s)
end

--- Receive header.
-- This will read the header from the network connection and store
-- it in the header field as well as return it.
-- @return table of header fields
function TcpRosConnection:receive_header()
   self.header = {}

   local rd = assert(self.socket:receive(4))
   local packet_size = struct.unpack("<!1i4", rd)

   local packet = assert(self.socket:receive(packet_size))

   local i = 1

   while i <= packet_size do
      local field_size
      field_size, i = struct.unpack("<!1i4", packet, i)

      local sub = string.sub(packet, i, i+field_size)
      local eqpos = string.find(sub, "=")
      local k = string.sub(sub, 1, eqpos - 1)
      local v = string.sub(sub, eqpos + 1, field_size)

      self.header[k] = v

      i = i + field_size
   end

   return self.header
end

--- Wait for a message to arrive.
-- This message blocks until a message has been received.
function TcpRosConnection:wait_for_message()
   repeat
      local selres = socket.select({self.socket}, {}, -1)
   until selres[self.socket]
   self:receive()
end

--- Check if data is available.
-- @return true if data can be read, false otherwise
function TcpRosConnection:data_available()
   local selres = socket.select({self.socket}, {}, 0)

   return selres[self.socket] ~= nil
end

--- Receive data from the network.
-- Upon return contains the new data in the payload field.
function TcpRosConnection:receive()
   local ok, packet_size_d, err = pcall(self.socket.receive, self.socket, 4)
   if not ok or packet_size_d == nil then
      error(err, (err == "closed") and 0)
   end
   local packet_size = struct.unpack("<!1i4", packet_size_d)

   if packet_size > 0 then
      self.payload = assert(self.socket:receive(packet_size))
   else
      self.payload = ""
   end
   self.received = true
   self.msg_stats.received = self.msg_stats.received + 1
   self.msg_stats.total    = self.msg_stats.total    + 1
end

--- Check if data has been received.
-- @return true if data has been received, false otherwise. This method will
-- return true only once if data has been received, consecutive calls will
-- return false unless more data has been read with receive().
function TcpRosConnection:data_received()
   local rv = self.received
   self.received = false
   return rv
end

--- Get connection statistics.
-- @return six values: bytes received, bytes send, socket age in seconds,
-- messages received, messages sent, total messages processed (sent + received)
function TcpRosConnection:get_stats()
   local bytes_recv, bytes_sent, age = self.socket:getstats()
   return bytes_recv, bytes_sent, age,
          self.msg_stats.received, self.msg_stats.sent, self.msg_stats.total
end

--- Send message.
-- @param message either a serialized message string or a Message
-- class instance.
function TcpRosConnection:send(message)
   if type(message) == "string" then
      assert(self.socket:send(message))
   else
      local s = message:serialize()
      assert(self.socket:send(s))
   end
   self.msg_stats.sent  = self.msg_stats.sent  + 1
   self.msg_stats.total = self.msg_stats.total + 1
end

--- Spin ros connection.
-- This will read messages from the wire when they become available. The
-- field max_receives_per_spin is used to determine the maximum number
-- of messages read per spin.
function TcpRosConnection:spin()
   self.messages = {}
   local i = 1
   while self:data_available() and i <= self.max_receives_per_spin do
      self:receive()
   end
end


TcpRosPubSubConnection = {}

--- Publisher/Subscriber connection constructor.
-- @param socket optionally a socket to use for communication
function TcpRosPubSubConnection:new(socket)
   local o = TcpRosConnection:new(socket)

   setmetatable(o, self)
   setmetatable(self, TcpRosConnection)
   self.__index = self

   return o
end

function TcpRosPubSubConnection:send_header(fields)
   assert(fields.type, "You must specify a type name")
   TcpRosConnection.send_header(self, fields)
  
   self.msgspec = roslua.msg_spec.get_msgspec(fields.type)
end

--- Receive data from the network.
-- Upon return contains the new messages in the messages array field.
function TcpRosPubSubConnection:receive()
   TcpRosConnection.receive(self)

   local message = self.msgspec:instantiate()
   message:deserialize(self.payload)
   table.insert(self.messages, message)
end

--- Receive header.
-- This receives the header, asserts the type and loads the message
-- specification into the msgspec field.
-- @return table of headers
function TcpRosPubSubConnection:receive_header()
   TcpRosConnection.receive_header(self)

   assert(self.header.type == "*" or self.header.type == self.msgspec.type,
          "Opposite site did not set proper type (got " .. self.header.type ..
          ", expected: " .. self.msgspec.type .. ")")

   return self.header
end


TcpRosServiceProviderConnection = {}

--- Service provider connection constructor.
-- @param socket optionally a socket to use for communication
function TcpRosServiceProviderConnection:new(socket)
   local o = TcpRosConnection:new(socket)

   setmetatable(o, self)
   setmetatable(self, TcpRosConnection)
   self.__index = self

   return o
end

--- Receive data from the network.
-- Upon return contains the new messages in the messages array field.
function TcpRosServiceProviderConnection:receive()
   TcpRosConnection.receive(self)

   local message = self.srvspec.reqspec:instantiate()
   message:deserialize(self.payload)
   table.insert(self.messages, message)
end


TcpRosServiceClientConnection = {}

--- Service client connection constructor.
-- @param socket optionally a socket to use for communication
function TcpRosServiceClientConnection:new(socket)
   local o = TcpRosConnection:new(socket)

   setmetatable(o, self)
   setmetatable(self, TcpRosConnection)
   self.__index = self

   return o
end

--- Receive data from the network.
-- Upon return contains the new message in the message field.
function TcpRosServiceClientConnection:receive()
   -- get OK-byte
   local ok, ok_byte_d, err = pcall(self.socket.receive, self.socket, 1)
   if not ok or ok_byte_d == nil then
      error("Reading OK byte failed: " .. err, (err == "closed") and 0)
   end
   local ok_byte = struct.unpack("<!1I1", ok_byte_d)

   TcpRosConnection.receive(self)

   if ok_byte == 1 then
      local message = self.srvspec.respspec:instantiate()
      message:deserialize(self.payload)
      self.message = message
   else
      if #self.payload > 0 then
         error("Service execution failed: " .. self.payload, 0)
      else
         error("Service execution failed (no error message received)")
      end
   end
end
