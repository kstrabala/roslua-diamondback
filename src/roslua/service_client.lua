
----------------------------------------------------------------------------
--  service_client.lua - Service client
--
--  Created: Fri Jul 30 10:34:47 2010 (at Intel Research, Pittsburgh)
--  License: BSD, cf. LICENSE file of roslua
--  Copyright  2010  Tim Niemueller [www.niemueller.de]
--             2010  Carnegie Mellon University
--             2010  Intel Research Pittsburgh
----------------------------------------------------------------------------

--- Service client.
-- This module contains the ServiceClient class to access services provided
-- by other ROS nodes. It is created using the function
-- <code>roslua.service_client()</code>.
-- <br /><br />
-- The service client employs the <code>__call()</code> meta method, such that
-- the service can be called just as <code>service_client(...)</code>. As arguments
-- you must pass the exact number of fields required for the request message in
-- the exact order and of the proper type as they are defined in the service
-- description file.
-- @copyright Tim Niemueller, Carnegie Mellon University, Intel Research Pittsburgh
-- @release Released under BSD license
module("roslua.service_client", package.seeall)

require("roslua")
require("roslua.srv_spec")

ServiceClient = { persistent = true }

--- Constructor.
-- The constructor can be called in two ways, either with positional or
-- named arguments. The latter form allows to set additional parameters.
-- In the positional form the ctor takes two arguments, the name and the type
-- of the service. For named parameters the parameter names are service (for
-- the name), type (service type) and persistent. If the latter is set to true
-- the connection to the service provider ROS node will not be closed after
-- one service call. This is beneficial when issuing many service calls in
-- a row, but no guarantee is made that the connection is re-opened if it
-- fails.<br /><br />
-- Examples:<br />
-- Positional: <code>ServiceClient:new("/myservice", "myservice/MyType")</code>
-- Named: <code>ServiceClient:new{service="/myservice", type="myservice/MyType",persistent=true}</code> (mind the curly braces instead of round brackets!)
-- @param args_or_service argument table or service name, see above
-- @param srvtype service type, only used in positional case
function ServiceClient:new(args_or_service, srvtype)
   local o = {}
   setmetatable(o, self)
   self.__index = self
   self.__call  = self.execute

   local lsrvtype
   if type(args_or_service) == "table" then
      o.service    = args_or_service[1] or args_or_service.service
      lsrvtype     = args_or_service[2] or args_or_service.type
      o.persistent = args_or_service.persistent
      o.simplified_return = args_or_service.simplified_return
   else
      o.service    = args_or_service
      lsrvtype     = srvtype
   end
   if roslua.srv_spec.is_srvspec(lsrvtype) then
      o.type    = type.type
      o.srvspec = lsrvtype
   else
      o.type    = lsrvtype
      o.srvspec = roslua.get_srvspec(lsrvtype)
   end

   assert(o.service, "Service name is missing")
   assert(o.type, "Service type is missing")

   if o.persistent then
      -- we don't care if it fails, we'll try again when the service is
      -- actually called, hence wrap in pcall.
      pcall(o.connect, o)
   end

   return o
end


--- Finalize instance.
function ServiceClient:finalize()
   if self.persistent and self.connection then
      -- disconnect
      self.connection:close()
      self.connection = nil
   end
end


--- Connect to service provider.
function ServiceClient:connect()
   assert(not self.connection, "Already connected")

   self.connection = roslua.tcpros.TcpRosServiceClientConnection:new()
   self.connection.srvspec = self.srvspec

   local uri = roslua.master:lookupService(self.service)
   assert(uri ~= "", "No provider found for service")

   -- parse uri
   local host, port = uri:match("rosrpc://([^:]+):(%d+)$")
   assert(host and port, "Parsing ROSRCP uri " .. uri .. " failed")

   self.connection:connect(host, port)
   self.connection:send_header{callerid=roslua.node_name,
			       service=self.service,
			       type=self.type,
			       md5sum=self.srvspec:md5(),
			       persistent=self.persistent and 1 or 0}
   self.connection:receive_header()
end

--- Initiate service execution.
-- This starts the execution of the service in a way it can be handled
-- concurrently. The request will be sent, afterwards the concexec_finished(),
-- concexec_result(), and concexec_wait() methods can be used.
-- @param args argument array
function ServiceClient:concexec_start(args)
   assert(not self.running, "A service call for "..self.service.." ("..self.type..") is already being executed")
   self.running = true
   self.concurrent = true
   self.finished = false

   local ok = true
   if not self.connection then
      ok = pcall(self.connect, self)
      if not ok then
	 self.concexec_error = "Connection failed"
      end
   end

   if ok then
      local m = self.srvspec.reqspec:instantiate()
      m:set_from_array(args)
      ok = pcall(self.connection.send, self.connection, m)
      if not ok then
	 self.concexec_error = "Sending message failed"
      end
   end

   self._concexec_failed = not ok
end

--- Wait for the execution to finish.
function ServiceClient:concexec_wait()
   assert(self.running, "Service "..self.service.." ("..self.type..") is not being executed")
   assert(self.concurrent, "Service "..self.service.." ("..self.type..") is not executed concurrently")
   assert(not self._concexec_failed, "Service "..self.service.." ("..self.type..") has failed")

   self.connection:wait_for_message()   
end


--- Check if execution is finished successfully.
-- Precondition is that the service is being concurrently executed.
-- @return true if the execution is finished and a result has been received, false otherwise
function ServiceClient:concexec_succeeded()
   assert(self.running, "Service "..self.service.." ("..self.type..") is not being executed")
   assert(self.concurrent, "Service "..self.service.." ("..self.type..") is not executed concurrently")

   if not self.finished then
      if self.connection:data_available() then
	 local ok, err = pcall(self.connection.receive, self.connection)
         if ok then
	          self.finished = true
         else
	          self.concexec_error = "Receiving result failed: " .. err
            self._concexec_failed = true
         end
      end
   end
   return self.finished
end

--- Check if execution has failed.
-- Precondition is that the service is being concurrently executed.
-- @return true if the execution is finished and a result has been received, false otherwise
function ServiceClient:concexec_failed()
   assert(self.running, "Service "..self.service.." ("..self.type..") is not being executed")
   assert(self.concurrent, "Service "..self.service.." ("..self.type..") is not executed concurrently")

   return self._concexec_failed == true
end

--- Check if execution has failed or succeeded
-- @return true if the execution is finished, false otherwise
function ServiceClient:concexec_finished()
   return self:concexec_succeeded() or self:concexec_failed()
end

--- Get execution result.
-- Precondition is that the service is being concurrently executed and has finished.
-- @return service return value
function ServiceClient:concexec_result()
   assert(self.running, "Service "..self.service.." ("..self.type..") is not being executed")
   assert(self.concurrent, "Service "..self.service.." ("..self.type..") is not executed concurrently")
   assert(self:concexec_succeeded(), "Service "..self.service.." ("..self.type..") is not finished")

   local message = self.connection.message
   if not self.persistent then
      self.connection:close()
      self.connection = nil
   end

   self.running = false

   assert(message, "Service "..self.service.." ("..self.type..") no result received")
   if self.simplified_return then
     local _, rv = message:generate_value_array(false)
     return unpack(rv)
   else
     return message
   end
end

--- Abort the execution.
-- Note that this does not actually stop the execution on the server side, rather
-- we just close the connection as to not receive the result. The connection will
-- be closed even if it is marked persistent. It will be reopened on the next call.
function ServiceClient:concexec_abort()
   self.running = false
   if not self.persistent then
      self.connection:close()
      self.connection = nil
   end
end

--- Execute service.
-- This method is set as __call entry in the meta table. See the module documentation
-- on the passed arguments. The method will return only after it has received a reply
-- from the service provider!
-- @param args argument array
function ServiceClient:execute(args)
   assert(not self.running, "A service call for "..self.service.." ("..self.type..") is already being executed")
   self.running = true
   self.concurrent = false

   if not self.connection then
      self:connect()
   end

   local m = self.srvspec.reqspec:instantiate()
   m:set_from_array(args)
   self.connection:send(m)
   self.connection:wait_for_message()

   local message = self.connection.message

   if not self.persistent then
      self.connection:close()
      self.connection = nil
   end

   self.running = false

   if self.simplified_return then
     local _, rv = message:generate_value_array(false)
     return unpack(rv)
   else
     return message
   end
end

