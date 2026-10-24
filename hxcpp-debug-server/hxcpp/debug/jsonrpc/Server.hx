package hxcpp.debug.jsonrpc;

import hxcpp.debug.jsonrpc.VariablesPrinter;
import hxcpp.debug.jsonrpc.Protocol;
#if haxe4
import sys.thread.Thread;
import sys.thread.Mutex;
import sys.thread.Deque;
#else
import cpp.vm.Thread;
import cpp.vm.Mutex;
import cpp.vm.Deque;
#end
import cpp.vm.Debugger;
import hxcpp.debug.jsonrpc.eval.Parser;
import hxcpp.debug.jsonrpc.eval.Interp;
import hxcpp.debug.jsonrpc.eval.Expr;
import hxcpp.debug.jsonrpc.eval.Interp;

enum abstract ScopeId(String) to String {
	var members = "Members";
	var locals = "Locals";
}

typedef BreakpointInfo = {
	var id:Int;
	var line:Int;
	@:optional var column:Int;
	@:optional var condition:Expr;
	@:optional var hitCondition:HitCondition;
	@:optional var logMessage:Array<LogPart>;
	var hits:Int;
}

/** How many hits a breakpoint takes to stop: the count of hits compared with `count` by `op`. **/
typedef HitCondition = {
	var op:String;
	var count:Int;
}

/** A piece of a log point's message: text, or an expression whose value goes in its place. **/
typedef LogPart = {
	var text:String;
	@:optional var expr:Expr;
}

/** A thread waiting in the debugger. **/
typedef StoppedThread = {
	var info:ThreadInfo;

	/** Index of the program's innermost frame; the server's own frames are above it. **/
	var top:Int;
}

/** A thread's stop the editor hasn't been told about yet, because another thread's is showing. **/
typedef PendingStop = {
	var threadId:Int;
	var method:String;
	var params:StopParams;
}

/** Values the editor can list the fields or items of, each kept until its thread goes on. **/
private class References {
	static var lastId:Int = 1000;

	var references:Map<Int, Value>;
	var owners:Map<Int, Int>;

	public function new() {
		clear();
	}

	public function create(ref:Value, threadId:Int):Int {
		var id = lastId;
		references[lastId] = ref;
		owners[lastId] = threadId;
		lastId++;
		return id;
	}

	public function get(id:Int):Value {
		return references[id];
	}

	/** The thread whose stop the value was read in. **/
	public function owner(id:Int):Int {
		return owners[id];
	}

	/** Forgets the values of a thread that went on. **/
	public function release(threadId:Int) {
		for (id in [for (id in owners.keys()) if (owners[id] == threadId) id]) {
			references.remove(id);
			owners.remove(id);
		}
	}

	public function clear() {
		references = new Map<Int, Value>();
		owners = new Map<Int, Int>();
	}
}

@:keep
class Server {
	var host:String;
	var port:Int;
	var listening:sys.net.Socket;
	var socket:sys.net.Socket;
	var stateMutex:Mutex;
	var socketMutex:Mutex;
	var scopes:Map<ScopeId, Array<String>>;
	var threads:Map<Int, String>;
	var breakpoints:Map<String, Array<BreakpointInfo>>;
	var requested:Map<String, SetBreakpointsParams>;
	var references:References;
	var started:Bool;
	var path2file:Map<String, String>;
	var file2path:Map<String, String>;
	var mainThread:Thread;
	var parser:Parser;
	var isWindows:Bool;

	/** Threads waiting in the debugger, by number. **/
	var stopped:Map<Int, StoppedThread>;

	/** The thread whose stop the editor was told about last, while it's stopped. **/
	var reported:Null<Int>;

	/** Threads whose stop the editor was told about, while they're stopped. **/
	var announced:Map<Int, Bool>;

	/** With `stopAll`, other threads' breakpoint and exception stops, shown one at a time on `continue`. **/
	var pending:Array<PendingStop>;

	/** The thread being stepped, and how. **/
	var stepping:Null<Int>;

	var stepType:Int;

	/** A pause was asked for and hasn't stopped a thread yet. **/
	var pausing:Bool;

	/**
		When a thread stops, stop the others too (the default), so that nothing changes while the editor
		shows the stop. Otherwise they go on, and `continue` and the steps only let the stopped one go.
	**/
	var stopAll:Bool;

	static var startQueue:Deque<Bool> = new Deque<Bool>();
	@:keep static var inst = {
		// The environment variables let a debugger choose the address each time it starts the program.
		var host:String = Sys.getEnv("HXCPP_DEBUG_HOST");
		if (host == null || host == "")
			host = Macro.getDefinedValue("HXCPP_DEBUG_HOST", "127.0.0.1");
		var envPort = Sys.getEnv("HXCPP_DEBUG_PORT");
		var port:Null<Int> = envPort == null ? null : Std.parseInt(envPort);
		if (port == null)
			port = Std.parseInt(Macro.getDefinedValue("HXCPP_DEBUG_PORT", "6972"));
		new Server(host, port);
	}

	public function new(host:String, port:Int) {
		this.host = host;
		this.port = port;
		stateMutex = new Mutex();
		socketMutex = new Mutex();
		scopes = new Map<ScopeId, Array<String>>();
		breakpoints = new Map<String, Array<BreakpointInfo>>();
		requested = new Map<String, SetBreakpointsParams>();
		references = new References();
		threads = new Map<Int, String>();
		path2file = new Map<String, String>();
		file2path = new Map<String, String>();
		mainThread = Thread.current();
		parser = new Parser();
		stopped = new Map<Int, StoppedThread>();
		announced = new Map<Int, Bool>();
		pending = [];
		pausing = false;
		stopAll = true;
		stepType = 0;
		started = false;
		isWindows = Sys.systemName() == "Windows";

		Debugger.enableCurrentThreadDebugging(false);
		if (connect()) {
			Thread.create(debuggerThreadMain);
			startQueue.pop(true);
			Debugger.enableCurrentThreadDebugging(true);
			startQueue.pop(true);
		} else {
			waitForAttach();
		}
	}

	private function connect():Bool {
		var socket:sys.net.Socket = new sys.net.Socket();
		socket.input.bigEndian = false;
		socket.output.bigEndian = false;

		try {
			var host = new sys.net.Host(host);
			if (host.ip == 0) {
				throw "Name lookup error.";
			}
			socket.connect(host, port);

			this.socket = socket;
			return true;
		} catch (e:Dynamic) {
			log('Failed to connect to vsc debugger server at $host:$port');
		}
		closeSocket();
		return false;
	}

	function waitForAttach() {
		var onMainThread = new haxe.Timer(500);
		onMainThread.run = function() {
			var callOnMainThread:Void->Void = Thread.readMessage(false);
			if (callOnMainThread == null)
				return;
			callOnMainThread();
		}
		Thread.create(createListeningSocket);
	}

	function createListeningSocket() {
		if (listening == null) {
			var socket:sys.net.Socket = new sys.net.Socket();
			socket.bind(new sys.net.Host("localhost"), port);
			socket.listen(1);
			listening = socket;
		}
		while (true) {
			var connectedSocket = listening.accept();
			mainThread.sendMessage(function() {
				if (this.socket == null) {
					this.socket = connectedSocket;
					onDebuggerAttached();
				}
			});
		}
	}

	function onDebuggerAttached() {
		Debugger.enableCurrentThreadDebugging(false);
		Thread.create(debuggerThreadMain);
		startQueue.pop(true);
		Debugger.enableCurrentThreadDebugging(true);
	}

	function onDebuggerDetached() {
		closeSocket();
		Debugger.setEventNotificationHandler(function(_, _, _, _, _, _, _) {});
		stateMutex.acquire();
		var wereStopped = stopped.keys().hasNext();
		clearStops();
		stateMutex.release();
		if (wereStopped) {
			Debugger.continueThreads(-1, 1);
			mainThread.sendMessage(function() {
				Debugger.enableCurrentThreadDebugging(false);
			});
		}
	}

	private function debuggerThreadMain() {
		Debugger.setEventNotificationHandler(handleThreadEvent);
		Debugger.enableCurrentThreadDebugging(false);
		Debugger.breakNow(true);

		mapFiles();
		#if scriptable
		// Scripts loaded from now on bring files that breakpoints may be waiting for
		var onLoaded:Dynamic = onScriptLoaded;
		untyped __cpp__("
#if defined(HXCPP_DBG_ON_SCRIPT_LOADED) || (HXCPP_API_LEVEL >= 500)
__hxcpp_dbg_setOnScriptLoadedFunction({0});
#endif
", onLoaded);
		#end

		var classes = Debugger.getClasses();
		@:privateAccess Interp.globals = new Map<String, Dynamic>();
		// globals declared inside hxcpp library not exposed to classes
		Interp.globals.set("Math", Math);
		Interp.globals.set("String", String);

		var appStructure = {};
		for (c in classes) {
			var pack = c.split(".");
			var klass = Type.resolveClass(c);
			var globalValue = klass;
			var currentNode = appStructure;

			var globalName = pack.pop();
			while (pack.length > 0) {
				var pathPart = pack.shift();
				if (!Reflect.hasField(currentNode, pathPart)) {
					Reflect.setField(currentNode, pathPart, {});
				}
				currentNode = Reflect.field(currentNode, pathPart);
			}
			Reflect.setField(currentNode, globalName, globalValue);
		}

		for (key in Reflect.fields(appStructure)) {
			var value = Reflect.field(appStructure, key);
			Interp.globals.set(key, value);
		}

		startQueue.push(true);
		while (true) {
			var m = try {
				readMessage();
			} catch (e:Dynamic) {
				onDebuggerDetached();
				return;
			}
			try {
				processMessage(m);
			} catch (e:Dynamic) {
				m.error = {code: ErrorCode.internal, message: Std.string(e)};
			}
			try {
				sendResponse(m);
			} catch (e:Dynamic) {
				onDebuggerDetached();
				return;
			}
		}
	}

	// How many files are compiled into the program. A cppia script's files come after them.
	var compiledFiles = -1;

	function mapFiles() {
		var fullPathes = Debugger.getFilesFullPath();
		var files = Debugger.getFiles();
		// The first call is at startup, before any script is loaded
		if (compiledFiles < 0)
			compiledFiles = files.length;
		for (i in 0...files.length) {
			var file = files[i];
			// hxcpp adds a script's files to each list unless that list has them already, so after the
			// compiled files the lists can be out of step: a script's "?" can share its full path with the
			// program's own. A script names its files the same way in both lists.
			var path = i < compiledFiles ? fullPathes[i] : file;
			// A cppia script names its files as Haxe was given them, often relative
			if (path == file && file != "?" && !haxe.io.Path.isAbsolute(file)) {
				path = findRequestedPath(file);
				if (path == null && sys.FileSystem.exists(file))
					path = sys.FileSystem.fullPath(file);
				if (path == null)
					path = file;
			}
			path2file[path2Key(path)] = file;
			file2path[path2Key(file)] = path;
		}
	}

	// The breakpoint path, as the editor gave it, whose end is this script file
	function findRequestedPath(file:String):String {
		var tail = "/" + path2Key(file).split("\\").join("/");
		for (params in requested) {
			var path = path2Key(params.file).split("\\").join("/");
			if (StringTools.endsWith(path, tail))
				return params.file;
		}
		return null;
	}

	// Sets the breakpoints asked for in files that only a newly loaded script has
	function onScriptLoaded() {
		stateMutex.acquire();
		mapFiles();
		for (params in requested) {
			var current = breakpoints[path2Key(params.file)];
			if (current == null || Lambda.exists(current, b -> b.id < 0))
				setBreakpoints(params);
		}
		stateMutex.release();
	}

	// Returns one id per requested breakpoint, in order: -1 for one that couldn't be set, because its
	// condition doesn't parse or no code from its file is loaded (yet, in a cppia host).
	function setBreakpoints(params:SetBreakpointsParams):Array<Int> {
		var key = path2Key(params.file);
		requested[key] = params;
		// A script loaded before this request is matched to the path now
		if (!path2file.exists(key))
			mapFiles();
		if (breakpoints.exists(key))
			for (rm in breakpoints[key])
				if (rm.id >= 0)
					Debugger.deleteBreakpoint(rm.id);
		var file = path2file[key];
		var result = [];
		var ids = [];
		for (b in params.breakpoints) {
			var bInfo:BreakpointInfo = {id: 0, line: b.line, hits: 0};
			try {
				if (b.condition != null && b.condition != "")
					bInfo.condition = parser.parseString(b.condition);
				if (b.hitCondition != null && b.hitCondition != "") {
					bInfo.hitCondition = parseHitCondition(b.hitCondition);
					if (bInfo.hitCondition == null)
						throw 'Not a hit count: ${b.hitCondition}';
				}
				if (b.logMessage != null && b.logMessage != "")
					bInfo.logMessage = parseLogMessage(b.logMessage);
			} catch (e:Dynamic) {
				ids.push(-1);
				continue;
			}
			bInfo.id = file == null ? -1 : Debugger.addFileLineBreakpoint(file, bInfo.line);
			result.push(bInfo);
			ids.push(bInfo.id);
		}
		breakpoints[key] = result;
		return ids;
	}

	private function readMessage():Message {
		if (socket == null)
			return null;

		var length:Int = socket.input.readInt32();
		// trace('Message Length: $length');
		var rawString = socket.input.readString(length);
		return haxe.Json.parse(rawString);
	}

	private function sendResponse(m:Message) {
		if (socket == null)
			return;

		socketMutex.acquire();
		var serialized:String = haxe.Json.stringify(m);
		var bytes = haxe.io.Bytes.ofString(serialized);
		socket.output.writeInt32(bytes.length);
		socket.output.writeBytes(bytes, 0, bytes.length);
		// trace('sendResponse: ${m.id} ${m.method}');
		socketMutex.release();
	}

	private function processMessage(m:Message) {
		switch (m.method) {
			case Protocol.Configure:
				if (m.params != null && m.params.stopAllThreads != null)
					stopAll = m.params.stopAllThreads;
				m.result = {features: ["threads", "frames", "hitConditions", "logPoints"]};

			case Protocol.SetBreakpoints:
				var params:SetBreakpointsParams = m.params;
				stateMutex.acquire();
				var ids = setBreakpoints(params);
				stateMutex.release();
				m.result = ids;

			case Protocol.Pause:
				stateMutex.acquire();
				pausing = true;
				stateMutex.release();
				Debugger.breakNow(true);

			case Protocol.Continue:
				if (!started) {
					// The program waits at startup for the editor's breakpoints: everything goes.
					stateMutex.acquire();
					clearStops();
					stateMutex.release();
					Debugger.continueThreads(-1, 1);
					started = true;
					startQueue.push(true);
				} else if (stopAll) {
					stateMutex.acquire();
					var next = pending.shift();
					if (next == null)
						clearStops();
					else
						reported = next.threadId;
					stateMutex.release();
					if (next == null)
						Debugger.continueThreads(-1, 1);
					else
						sendEvent(new NotificationMethod<StopParams>(next.method), next.params);
				} else {
					stateMutex.acquire();
					var threadId:Int = m.params.threadId;
					// Threads only halted by a pause, which the editor doesn't show as stopped, go with it.
					var going = [for (n in stopped.keys()) if (n == threadId || !announced.exists(n)) n];
					stateMutex.release();
					for (n in going)
						resumeOnly(n);
				}

			case Protocol.Threads:
				stateMutex.acquire();
				var ids = [for (tid in threads.keys()) tid];
				for (tid in stopped.keys())
					if (!threads.exists(tid))
						ids.push(tid);
				ids.sort((a, b) -> a - b);
				m.result = [for (tid in ids) {id: tid, name: 'Thread$tid'}];
				stateMutex.release();

			case Protocol.GetScopes:
				m.result = [];
				stateMutex.acquire();
				var thread = stoppedThread(m.params);
				if (thread != null) {
					var threadId = thread.info.number;
					var frameId:Int = m.params.frameId;
					var names:Array<String> = [];
					for (varName in Debugger.getStackVariables(threadId, frameId, false)) {
						if (varName == "this") {
							var value:Dynamic = Debugger.getStackVariableValue(threadId, frameId, "this", false);
							m.result.push({id: references.create(VariablesPrinter.resolveValue(value), threadId), name: ScopeId.members});
						} else {
							if (names.length == 0)
								m.result.push({id: references.create(Locals(threadId, frameId, names), threadId), name: ScopeId.locals});
							names.push(varName);
						}
					}
				}
				stateMutex.release();

			case Protocol.GetVariables:
				m.result = [];
				stateMutex.acquire();
				try {
					var refId:Int = m.params.variablesReference;
					var value:Value = references.get(refId);
					var threadId = references.owner(refId);
					if (value != null) {
						for (v in VariablesPrinter.getInnerVariables(value, m.params.start, m.params.count))
							m.result.push(describe(v.name, v.type, v.value, threadId));
					}
				} catch (e:Dynamic) {
					stateMutex.release();
					throw e;
				}
				stateMutex.release();

			case Protocol.SetVariable:
				stateMutex.acquire();
				try {
					var thread = stoppedThread(m.params);
					if (thread == null)
						throw "The program isn't stopped.";
					var threadId = thread.info.number;
					var frameId:Int = m.params.frameId != null ? m.params.frameId : thread.top;
					// The new value is an expression, evaluated in the frame.
					var interp = VariablesPrinter.initInterp(threadId, frameId, true);
					var value:Dynamic = VariablesPrinter.execute(parser, interp, m.params.value);
					var result:Dynamic = Debugger.setStackVariableValue(threadId, frameId, m.params.expr, value, false);
					if (result == Debugger.NONEXISTENT_VALUE)
						throw 'There is no local variable ${m.params.expr} here.';
					if (result == Debugger.THREAD_NOT_STOPPED)
						throw "The program isn't stopped.";
					m.result = describe(m.params.expr, VariablesPrinter.getType(result), VariablesPrinter.resolveValue(result), threadId);
				} catch (e:Dynamic) {
					stateMutex.release();
					throw e;
				}
				stateMutex.release();

			case Protocol.Completions:
				stateMutex.acquire();
				var completions:Array<CompletionItem> = [];
				var thread = stoppedThread(m.params);
				if (thread != null) {
					var frameId:Int = m.params.frameId != null ? m.params.frameId : thread.top;
					for (variable in Debugger.getStackVariables(thread.info.number, frameId, false))
						completions.push({label: variable});
				}
				m.result = completions;
				stateMutex.release();

			case Protocol.Evaluate:
				stateMutex.acquire();
				try {
					var thread = stoppedThread(m.params);
					if (thread == null)
						throw "The program isn't stopped.";
					var threadId = thread.info.number;
					var frameId:Int = m.params.frameId != null ? m.params.frameId : thread.top;
					var v = VariablesPrinter.evaluate(parser, m.params.expr, threadId, frameId);
					m.result = describe(m.params.expr, v.type, v.value, threadId);
				} catch (e:Dynamic) {
					stateMutex.release();
					throw e;
				}
				stateMutex.release();

			case Protocol.StackTrace:
				m.result = [];
				stateMutex.acquire();
				var thread = stoppedThread(m.params);
				if (thread != null) {
					for (i in 0...thread.top + 1) {
						var s = thread.info.stack[i];
						m.result.unshift({
							id: i,
							name: '${s.className}.${s.functionName}',
							source: file2path[path2Key(s.fileName)],
							line: s.lineNumber,
							column: 0,
							artificial: false
						});
					}
				}
				stateMutex.release();

			case Protocol.Next:
				step(m.params, Debugger.STEP_OVER);

			case Protocol.StepIn:
				step(m.params, Debugger.STEP_INTO);

			case Protocol.StepOut:
				step(m.params, Debugger.STEP_OUT);
		}
	}

	/** A value as the editor shows it. One with fields or items gets a reference to list them by. **/
	function describe(name:String, type:String, value:Value, threadId:Int):VarInfo {
		var info:VarInfo = {
			name: name,
			type: type,
			value: "",
			variablesReference: 0
		};
		switch (value) {
			case IntIndexed(v, length, _):
				info.variablesReference = references.create(value, threadId);
				info.indexedVariables = length;
				info.value = Std.string(v);
			case StringIndexed(_, printedValue, names, _):
				info.variablesReference = references.create(value, threadId);
				info.namedVariables = names.length;
				info.value = printedValue;
			case Single(v):
				info.value = v;
			case NameValueList(_, _) | Locals(_, _, _):
				throw "impossible";
		}
		return info;
	}

	/** The stopped thread a request is about: its `threadId`, or the one whose stop was shown last. **/
	function stoppedThread(params:Dynamic):Null<StoppedThread> {
		var threadId:Null<Int> = params != null && params.threadId != null ? params.threadId : reported;
		return threadId == null ? null : stopped[threadId];
	}

	function step(params:Dynamic, type:Int) {
		stateMutex.acquire();
		var threadId:Int = params != null && params.threadId != null ? params.threadId : (reported != null ? reported : 0);
		stepping = threadId;
		stepType = type;
		forget(threadId);
		stateMutex.release();
		// Only this thread runs; with `stopAll`, the others stay stopped.
		Debugger.stepThread(threadId, type, 1);
	}

	private function sendEvent<T>(event:NotificationMethod<T>, ?params:T) {
		var m = {
			method: event,
			params: params
		};
		sendResponse(m);
	}

	function handleThreadEvent(threadNumber:Int, event:Int, stackFrame:Int, className:String, functionName:String, fileName:String, lineNumber:Int) {
		switch (event) {
			case Debugger.THREAD_TERMINATED:
				stateMutex.acquire();
				threads.remove(threadNumber);
				forget(threadNumber);
				stateMutex.release();
				sendEvent(Protocol.ThreadExit, {threadId: threadNumber});

			case Debugger.THREAD_CREATED | Debugger.THREAD_STARTED:
				// hxcpp starts each thread unable to stop. This runs on the new thread, which can enable itself.
				if (event == Debugger.THREAD_CREATED)
					Debugger.enableCurrentThreadDebugging(true);
				stateMutex.acquire();
				threads.set(threadNumber, 'Thread${threadNumber}');
				// THREAD_STARTED also comes each time a stopped thread goes on.
				forget(threadNumber);
				stateMutex.release();
				sendEvent(Protocol.ThreadStart, {threadId: threadNumber});

			case Debugger.THREAD_STOPPED:
				var info = Debugger.getThreadInfo(threadNumber, false);
				var thread:StoppedThread = {info: info, top: programTop(info)};
				stateMutex.acquire();
				stopped[threadNumber] = thread;
				stateMutex.release();
				if (info.status == ThreadInfo.STATUS_STOPPED_BREAKPOINT) {
					if (breaksHere(thread))
						announce(threadNumber, Protocol.BreakpointStop, {threadId: threadNumber}, stopAll);
					else
						goOn(threadNumber);
				} else if (info.status == ThreadInfo.STATUS_STOPPED_BREAK_IMMEDIATE) {
					stateMutex.acquire();
					var stepped = stepping == threadNumber;
					if (stepped)
						stepping = null;
					var wasPausing = pausing;
					var show = stepped || pausing || reported == null;
					if (!stepped)
						pausing = false;
					stateMutex.release();
					// Otherwise it's one of the threads stopped to keep still while another's stop shows.
					if (show)
						announce(threadNumber, Protocol.PauseStop, {threadId: threadNumber}, stepped ? stopAll : true);
				} else {
					announce(threadNumber, Protocol.ExceptionStop, {threadId: threadNumber, text: info.criticalErrorDescription}, stopAll);
				}
		}
	}

	/**
		Tells the editor a thread stopped, and with `stopAll`, stops the others. While another thread's
		stop shows, with `stopAll`, the stop waits its turn instead (`continue` shows it).
	**/
	function announce(threadNumber:Int, method:NotificationMethod<StopParams>, params:StopParams, allThreadsStopped:Bool) {
		stateMutex.acquire();
		if (stopAll && reported != null && reported != threadNumber) {
			params.allThreadsStopped = true;
			pending.push({threadId: threadNumber, method: method, params: params});
			stateMutex.release();
			return;
		}
		reported = threadNumber;
		announced[threadNumber] = true;
		stateMutex.release();
		if (stopAll)
			Debugger.breakNow(false);
		params.allThreadsStopped = allThreadsStopped;
		sendEvent(method, params);
	}

	/**
		Whether a thread at a breakpoint stops there: its condition holds, its hit count is reached, and
		it isn't a log point, which prints its message instead.
	**/
	function breaksHere(thread:StoppedThread):Bool {
		stateMutex.acquire();
		var b = findBreakpoint(thread.info.breakpoint);
		stateMutex.release();
		if (b == null)
			return true;
		var interp:Interp = null;
		if (b.condition != null || b.logMessage != null)
			interp = VariablesPrinter.initInterp(thread.info.number, thread.top, true);
		if (b.condition != null && !isConditionPass(interp, b.condition))
			return false;
		stateMutex.acquire();
		var hits = ++b.hits;
		stateMutex.release();
		if (b.hitCondition != null && !hitReached(b.hitCondition, hits))
			return false;
		if (b.logMessage != null) {
			sendEvent(Protocol.Output, {text: logLine(interp, b.logMessage) + "\n", threadId: thread.info.number});
			return false;
		}
		return true;
	}

	/** After a breakpoint that doesn't stop: the thread goes on, unless everything is being held still. **/
	function goOn(threadNumber:Int) {
		stateMutex.acquire();
		var held = stopAll && reported != null;
		stateMutex.release();
		if (!held)
			resumeOnly(threadNumber);
	}

	/** Lets one thread go on and leaves the others as they are. **/
	function resumeOnly(threadNumber:Int) {
		stateMutex.acquire();
		forget(threadNumber);
		var step = stepping != threadNumber ? stepping : null;
		var type = stepType;
		stateMutex.release();
		// hxcpp only lets a single thread go through a step, here one that never stops (STEP_NONE)...
		Debugger.stepThread(threadNumber, 0, 1);
		// ...which replaces a step in progress on another thread, so that one is set again.
		if (step != null)
			Debugger.stepThread(step, type, 1);
	}

	/** Forgets that a thread is stopped (it went on, or ended). Call with `stateMutex` held. **/
	function forget(threadNumber:Int) {
		stopped.remove(threadNumber);
		announced.remove(threadNumber);
		references.release(threadNumber);
		if (reported == threadNumber)
			reported = null;
	}

	/** Forgets every stop, as everything goes on. Call with `stateMutex` held. **/
	function clearStops() {
		stopped = new Map<Int, StoppedThread>();
		announced = new Map<Int, Bool>();
		pending = [];
		reported = null;
		stepping = null;
		references.clear();
	}

	function findBreakpoint(id:Int):Null<BreakpointInfo> {
		for (list in breakpoints)
			for (b in list)
				if (b.id == id)
					return b;
		return null;
	}

	function isConditionPass(interp:Interp, condition:Expr):Bool {
		try {
			return interp.execute(condition) == true;
		} catch (e:Dynamic) {}

		return false;
	}

	static function parseHitCondition(text:String):Null<HitCondition> {
		// Not a static: the server starts while the class's statics are still being set up.
		var hitPattern = ~/^\s*(>=|<=|==|=|>|<|%|)\s*([0-9]+)\s*$/;
		if (!hitPattern.match(text))
			return null;
		var op = hitPattern.matched(1);
		return {op: op == "" ? ">=" : op, count: Std.parseInt(hitPattern.matched(2))};
	}

	static function hitReached(condition:HitCondition, hits:Int):Bool {
		return switch (condition.op) {
			case "==" | "=": hits == condition.count;
			case ">": hits > condition.count;
			case "<": hits < condition.count;
			case "<=": hits <= condition.count;
			case "%": condition.count > 0 && hits % condition.count == 0;
			case _: hits >= condition.count;
		}
	}

	/** A log message split at each `{expression}`, parsed once rather than at every hit. **/
	function parseLogMessage(message:String):Array<LogPart> {
		var parts:Array<LogPart> = [];
		var placeholder = ~/\{([^{}]*)\}/;
		var rest = message;
		while (placeholder.match(rest)) {
			if (placeholder.matchedLeft() != "")
				parts.push({text: placeholder.matchedLeft()});
			var source = placeholder.matched(1);
			try {
				parts.push({text: source, expr: parser.parseString(source)});
			} catch (e:Dynamic) {
				parts.push({text: '{$source}'});
			}
			rest = placeholder.matchedRight();
		}
		if (rest != "")
			parts.push({text: rest});
		return parts;
	}

	function logLine(interp:Interp, parts:Array<LogPart>):String {
		var line = new StringBuf();
		for (part in parts) {
			if (part.expr == null) {
				line.add(part.text);
				continue;
			}
			try {
				line.add(Std.string(interp.execute(part.expr)));
			} catch (e:Dynamic) {
				line.add('{${part.text}: ${VariablesPrinter.describeError(e)}}');
			}
		}
		return line.toString();
	}

	/** Index of the innermost frame of the program's own: the stack's top holds the server's frames. **/
	static function programTop(info:ThreadInfo):Int {
		var i = info.stack.length - 1;
		while (i >= 0 && isServerFrame(info.stack[i]))
			i--;
		return i;
	}

	static function isServerFrame(frame:StackFrame):Bool {
		return frame.className == "cpp.vm.Debugger" || StringTools.startsWith(frame.className, "hxcpp.debug.jsonrpc.");
	}

	function closeSocket() {
		if (socket != null) {
			socket.close();
			socket = null;
		}
	}

	function path2Key(path:String):String {
		return (isWindows) ? path.toUpperCase() : path;
	}

	public static function log(message:String) {
		trace(message);
	}
}
