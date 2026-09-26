local H = {}

function H.read(path)
	local f = assert(io.open(path, "r"))
	local s = f:read("*a")
	f:close()
	return s
end

function H.json(path)
	return require("json").decode(H.read(path))
end

--- Fake awesome dependencies for model tests.
function H.deps(t0)
	local d = { t = t0 or 1758560000, spawned = {}, notifications = {}, timers = {}, warnings = {}, headers = {} }
	d.now = function()
		return d.t
	end
	d.spawn = function(argv, cb)
		d.spawned[#d.spawned + 1] = { argv = argv, cb = cb }
		return d.spawn_result
	end
	-- source/api.lua keeps the token in a header file; keep it in memory instead.
	d.write_header = function(_, token)
		local path = "spec/tmp/fake-auth-" .. (#d.spawned + 1) .. ".hdr"
		d.headers[path] = "Authorization: Bearer " .. token
		return path
	end
	d.remove = function(path)
		d.headers[path] = nil
	end
	d.timer = function(args)
		local tm = {
			timeout = args.timeout,
			single_shot = args.single_shot,
			callback = args.callback,
			started = args.autostart or false,
			again_calls = 0,
		}
		function tm:start()
			self.started = true
		end
		function tm:stop()
			self.started = false
		end
		function tm:again()
			self.started = true
			self.again_calls = self.again_calls + 1
		end
		function tm:fire()
			assert(self.started, "firing a stopped timer")
			if self.single_shot then
				self.started = false
			end
			self.callback()
		end
		d.timers[#d.timers + 1] = tm
		return tm
	end
	d.notify = function(args)
		d.notifications[#d.notifications + 1] = args
	end
	d.warn = function(msg)
		d.warnings[#d.warnings + 1] = msg
	end
	return d
end

--- The Authorization header of a spawned curl argv, whether inline or passed as -H @file.
function H.auth_header(d, argv)
	for i, a in ipairs(argv) do
		if argv[i - 1] == "-H" then
			if a:match("^Authorization:") then
				return a
			elseif a:sub(1, 1) == "@" then
				return d.headers[a:sub(2)]
			end
		end
	end
	return nil
end

--- Simulate a finished curl run for the last spawned command.
function H.respond(d, body, http)
	local s = d.spawned[#d.spawned]
	assert(s, "nothing was spawned")
	s.cb(body .. "\n" .. tostring(http), "", "exit", 0)
end

return H
