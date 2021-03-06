
----------------------------------------------------------------------------
--  utils.lua - Utilities used in the code
--
--  Created: Thu Jul 29 10:59:22 2010 (at Intel Research, Pittsburgh)
--  License: BSD, cf. LICENSE file of roslua
--  Copyright  2010  Tim Niemueller [www.niemueller.de]
--             2010  Carnegie Mellon University
--             2010  Intel Research Pittsburgh
----------------------------------------------------------------------------

--- General roslua utilities.
-- This module contains useful functions used in roslua.
-- @copyright Tim Niemueller, Carnegie Mellon University, Intel Research Pittsburgh
-- @release Released under BSD license
module("roslua.utils", package.seeall)

local asserted_rospack = false
--- Assert availability of rospack.
-- Throws an error if rospack cannot be executed, for example because ROS is
-- not installed or the binary is not in the PATH.
function assert_rospack()
   if not asserted_rospack then
      local rv = os.execute("rospack 2>/dev/null")
      assert(rv == 0, "Cannot find rospack command, must be in PATH")
      asserted_rospack = true
   end
end

local rospack_path_cache = {}

--- Get path for a package.
-- Uses rospack to find the path to a certain package. The path is cached so
-- that consecutive calls will not trigger another rospack execution, but are
-- rather handled directly from the cache. An error is thrown if the package
-- cannot be found.
-- @return path to give package
function find_rospack(package)
   if not rospack_path_cache[package] then
      local p = io.popen("rospack find " .. package .. " 2>/dev/null")
      local path = p:read("*a")
      -- strip trailing newline
      rospack_path_cache[package] = string.gsub(path, "^(.+)\n$", "%1")
      p:close()
   end

   assert(rospack_path_cache[package], "Package path could not be found for " .. package)
   assert(rospack_path_cache[package] ~= "", "Package path could not be found for " .. package)
   return rospack_path_cache[package]
end

--- Split string.
-- Splits a string at a given separator and returns the parts in a table.
-- @param s string to split
-- @param sep separator to split at
-- @return table with splitted parts
function split(s, sep)
   local sep, fields = sep or ":", {}
   local pattern = string.format("([^%s]+)", sep)
   string.gsub(s, pattern, function(c) fields[#fields+1] = c end)
   return fields
end

--- Package loader to find Lua modules in ROS packages.
-- This will use the first part of the module name and assume it to
-- be the name of a ROS package. It will then try to determine the path using
-- rospack and if found try to load the module in the package directory.
-- Additionally it appends the string "_lua" to the package name, thus
-- allowing a module named my_module in the ROS package my_module_lua. This
-- is done to allow to mark Lua ROS packages, but avoid having to have
-- the _lua suffix in module names. The suffixed version takes precedence.
-- @param module module name as given to require()
-- @return function of loaded code if module was found, nil otherwise
function package_loader(module)
   local package = string.match(module, "^[^%.]+")
   local modname = string.match(module, "[^%.]+$")
   if not package or not modname then return end

   local try_paths = { "%s/src/%s.lua", "%s/src/%s/%s.lua", "%s/src/%s/init.lua",
		       "%s/src/lua/%s.lua", "%s/src/lua/%s/%s.lua", "%s/src/lua/%s/init.lua" }
   local try_packages = { package .. "_lua", package }
   local errmsg = ""

   for _, package in ipairs(try_packages) do
      local ok, packpath = pcall(find_rospack, package)
      if ok then
	 errmsg = errmsg .. string.format("\n\tFound matching ROS package %s at s (ROS Lua loader)",
					  package, packpath)

	 for _, tp in ipairs(try_paths) do
	    local modulepath = string.gsub(module, "%.", "/")
	    local filename = string.format(tp, packpath, modulepath, modname)
	    local file = io.open(filename, "rb")
	    if file then
	       -- Compile and return the module
	       if _G.add_watchfile then _G.add_watchfile(filename) end
	       local chunk, errmsg = loadstring(assert(file:read("*a")), filename)
	       if chunk then
		  return chunk
	       else
		  error("Failed loading " .. filename .. ": " .. errmsg)
	       end
	    end
	    errmsg = errmsg .. string.format("\n\tno file %s (ROS Lua loader)", filename)
	 end
      else
	 errmsg = errmsg .. "\n\tno ROS package '" .. package .. "' found (ROS Lua loader)"
      end
   end

   return errmsg
end


--- Package loader to find Lua modules written in C in ROS packages.
-- This will use the first part of the module name and assume it to
-- be the name of a ROS package. It will then try to determine the path using
-- rospack and if found try to load the module in the package directory.
-- Additionally it appends the string "_lua" to the package name, thus
-- allowing a module named my_module in the ROS package my_module_lua. This
-- is done to allow to mark Lua ROS packages, but avoid having to have
-- the _lua suffix in module names. The suffixed version takes precedence.
-- @param module module name as given to require()
-- @return function of loaded code if module was found, nil otherwise
function c_package_loader(module)
   local package_name = string.match(module, "^[^%.]+")
   local submod       = string.sub(module, #package_name + 2)

   local try_packages = { package_name .. "_lua", package_name }
   local errmsg = ""

   for _, tpackage in ipairs(try_packages) do
      local ok, packpath = pcall(find_rospack, tpackage)
      if ok then
	 errmsg = errmsg .. string.format("\n\tFound matching ROS package %s at %s (ROS C loader)",
					  tpackage, packpath)

	 local try_paths = {{string.format("%s/lib/%s.luaso", packpath, package_name), string.gsub(module, "%.", "_")}}
	 if submod ~= nil or submod ~= "" then
	    table.insert(try_paths, {string.format("%s/lib/%s.luaso", packpath, submod),
				     string.gsub(submod, "%.", "_")})
	 end

	 for _, pathinfo in ipairs(try_paths) do
	    local symbolname = string.gsub(module, "%.", "_")
	    local file = io.open(pathinfo[1], "rb")
	    if file then
	       file:close()
	       -- Load and return the module loader
	       if _G.add_watchfile then _G.add_watchfile(pathinfo[1]) end
	       local loader, msg = package.loadlib(pathinfo[1], "luaopen_"..pathinfo[2])
	       if not loader then
		  error("error loading module '" .. module .. "' from file '".. pathinfo[1] .."':\n\t" .. msg, 3)
	       end
	       return loader
	    end
	    errmsg = errmsg .. "\n\tno file '" .. pathinfo[1] .. "' (ROS C loader)"
	 end
      else
	 errmsg = errmsg .. "\n\tno ROS package '" .. tpackage .. "' found (ROS C loader)"
      end
   end

   return errmsg
end
