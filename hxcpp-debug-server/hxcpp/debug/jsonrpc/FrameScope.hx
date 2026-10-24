package hxcpp.debug.jsonrpc;

#if haxe4
import sys.thread.Mutex;
#else
import cpp.vm.Mutex;
#end

/** Where a stopped frame's code is: its class, and the full path of its source file, if known. **/
typedef FrameContext = {
	var className:String;
	@:optional var file:String;
}

/** What a source file brings into scope, read from its `import` and `using` lines. **/
private typedef FileImports = {
	var time:Float;

	/** `import a.b.C;` and `import a.b.C as D;`, by the name they give. **/
	var imports:Map<String, String>;

	/** `import a.b.*;` **/
	var packages:Array<String>;

	var usings:Array<String>;
}

/**
	The types a frame's code names without their package, as the compiler saw them: the imports and
	usings of its source file and of the `import.hx` files in the folders above it, the types of its own
	package, and any type whose name no other type in the program has.
**/
class FrameScope {
	// Set up by `init` rather than as statics with values: the server starts while statics are being set.
	static var mutex:Mutex;
	static var classes:Array<String>;
	static var unique:Map<String, String>;
	static var files:Map<String, FileImports>;

	/** Takes the program's types, once, before any frame is evaluated. **/
	public static function init(classNames:Array<String>) {
		mutex = new Mutex();
		classes = classNames;
		files = new Map<String, FileImports>();
		unique = new Map<String, String>();
		var seen = new Map<String, Int>();
		for (path in classNames) {
			var name = shortName(path);
			seen[name] = (seen.exists(name) ? seen[name] : 0) + 1;
			unique[name] = path;
		}
		for (name in seen.keys())
			if (seen[name] > 1)
				unique.remove(name);
	}

	/** The type with this name, if it's the only one in the program. **/
	public static function uniqueType(name:String):Dynamic {
		if (unique == null || !unique.exists(name))
			return null;
		return resolveType(unique[name]);
	}

	/** Sets up `interp` for code in the frame: its imported types, its package's, and its usings. **/
	public static function apply(interp:hxcpp.debug.jsonrpc.eval.Interp, context:Null<FrameContext>) {
		interp.fallback = uniqueType;
		if (context == null || classes == null)
			return;
		var aliases = interp.aliases;
		var pack = packageOf(context.className);
		for (path in classes)
			if (packageOf(path) == pack)
				setAlias(aliases, shortName(path), path);
		if (context.file == null)
			return;
		var usings:Array<String> = [];
		// import.hx files apply to their folder and those below, so the outermost goes first.
		var sources = importFiles(context.file);
		sources.push(context.file);
		for (source in sources) {
			var found = read(source);
			if (found == null)
				continue;
			for (p in found.packages)
				for (path in classes)
					if (packageOf(path) == p)
						setAlias(aliases, shortName(path), path);
			for (name in found.imports.keys())
				setAlias(aliases, name, found.imports[name]);
			usings = usings.concat(found.usings);
		}
		for (path in usings) {
			var type = resolveType(path);
			if (type != null)
				interp.usings.push(type);
		}
	}

	static function setAlias(aliases:Map<String, Dynamic>, name:String, path:String) {
		var type = resolveType(path);
		if (type != null)
			aliases[name] = type;
	}

	/** A class or enum by its path. `a.b.Module.Sub`, a module's other type, is `a.b.Sub` at run time. **/
	static function resolveType(path:String):Dynamic {
		var type:Dynamic = Type.resolveClass(path);
		if (type == null)
			type = Type.resolveEnum(path);
		if (type == null) {
			var parts = path.split(".");
			if (parts.length >= 2) {
				var sub = parts.pop();
				parts.pop();
				parts.push(sub);
				var other = parts.join(".");
				type = Type.resolveClass(other);
				if (type == null)
					type = Type.resolveEnum(other);
			}
		}
		return type;
	}

	/** The `import.hx` files that apply to `file`, from the outermost folder in. **/
	static function importFiles(file:String):Array<String> {
		var found = [];
		var dir = haxe.io.Path.directory(file);
		while (dir != "" && dir != "/" && found.length < 50) {
			var candidate = haxe.io.Path.join([dir, "import.hx"]);
			if (sys.FileSystem.exists(candidate))
				found.unshift(candidate);
			var parent = haxe.io.Path.directory(dir);
			if (parent == dir)
				break;
			dir = parent;
		}
		return found;
	}

	static function read(file:String):Null<FileImports> {
		mutex.acquire();
		try {
			if (!sys.FileSystem.exists(file)) {
				mutex.release();
				return null;
			}
			var time = sys.FileSystem.stat(file).mtime.getTime();
			var known = files[file];
			if (known == null || known.time != time) {
				known = parse(sys.io.File.getContent(file), time);
				files[file] = known;
			}
			mutex.release();
			return known;
		} catch (e:Dynamic) {
			mutex.release();
			return null;
		}
	}

	static function parse(text:String, time:Float):FileImports {
		var result:FileImports = {
			time: time,
			imports: new Map<String, String>(),
			packages: [],
			usings: []
		};
		var importLine = ~/^\s*import\s+([A-Za-z_][\w.]*?)(\.\*)?(?:\s+(?:as|in)\s+([A-Za-z_]\w*))?\s*;/;
		var usingLine = ~/^\s*using\s+([A-Za-z_][\w.]*)\s*;/;
		for (line in text.split("\n")) {
			if (importLine.match(line)) {
				var path = importLine.matched(1);
				if (importLine.matched(2) != null && importLine.matched(2) != "")
					result.packages.push(path);
				else
					result.imports[importLine.matched(3) != null && importLine.matched(3) != "" ? importLine.matched(3) : shortName(path)] = path;
			} else if (usingLine.match(line)) {
				result.usings.push(usingLine.matched(1));
			}
		}
		return result;
	}

	static function shortName(path:String):String {
		return path.substr(path.lastIndexOf(".") + 1);
	}

	static function packageOf(path:String):String {
		var dot = path.lastIndexOf(".");
		return dot < 0 ? "" : path.substr(0, dot);
	}
}
