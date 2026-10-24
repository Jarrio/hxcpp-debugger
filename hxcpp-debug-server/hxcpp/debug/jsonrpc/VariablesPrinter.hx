package hxcpp.debug.jsonrpc;

import hxcpp.debug.jsonrpc.eval.Parser;
import hxcpp.debug.jsonrpc.eval.Interp;
import hxcpp.debug.jsonrpc.eval.Expr.Error;
import hxcpp.debug.jsonrpc.eval.Tools;

enum VarType {
	TypeNull;
	TypeInt;
	TypeFloat;
	TypeBool;
	TypeClass(name:String);
	TypeAnonymous(fieldsCount:Int);
	TypeFunction;
	TypeEnum(name:String);
}

enum Value {
	Single(val:Dynamic);
	IntIndexed(val:Dynamic, length:Int, fieldAccess:Dynamic->Int->Dynamic);
	StringIndexed(val:Dynamic, printedValue:String, names:Array<String>, fieldsAsString:Bool, fieldAccess:Dynamic->String->Dynamic);
	NameValueList(names:Array<String>, values:Array<Dynamic>);
	/** A stopped frame's local variables, read when asked for, so that a changed one shows its new value. **/
	Locals(threadId:Int, frameId:Int, names:Array<String>);
}

typedef Variable = {
	var name:String;
	var type:String;
	var value:Value;
}

class VariablesPrinter {
	public static function getInnerVariables(value:Value, start:Int = 0, count:Int = -1):Array<Variable> {
		var result = [];
		switch (value) {
			case NameValueList(names, values):
				if (count < 0)
					count = names.length - start;
				for (i in start...start + count) {
					var name = names[i];
					var value = values[i];
					if (value == null)
						continue;
					result.push({
						name: name,
						value: resolveValue(value),
						type: getType(value)
					});
				}

			case Locals(threadId, frameId, names):
				if (count < 0)
					count = names.length - start;
				for (i in start...start + count) {
					var value:Dynamic = cpp.vm.Debugger.getStackVariableValue(threadId, frameId, names[i], false);
					result.push({
						name: names[i],
						value: resolveValue(value),
						type: getType(value)
					});
				}

			case StringIndexed(val, _, names, fieldsAsString, fieldAccess):
				if (count < 0)
					count = names.length;
				var filteredNames = names.slice(start, start + count);
				for (n in filteredNames) {
					var value = fieldAccess(val, n);
					result.push({
						name: if (fieldsAsString) '"$n"' else n,
						value: resolveValue(value),
						type: getType(value)
					});
				}

			case IntIndexed(val, length, fieldAccess):
				if (count < 0)
					count = length;
				for (i in start...start + count) {
					var value = fieldAccess(val, i);
					result.push({
						name: '$i',
						value: resolveValue(value),
						type: getType(value)
					});
				}

			case Single(_):
				throw "not structured";
		}
		return result;
	}

	public static function resolveValue(value:Dynamic):Value {
		return switch (Type.typeof(value)) {
			case TNull, TUnknown, TInt, TFloat, TBool, TFunction:
				Single(Std.string(value));
			#if (haxe_ver >= 5)
			case TInt64:
				Single(Std.string(value));
			#end

			case TClass(String):
				Single('"$value"');

			case TEnum(e):
				Single(Std.string(value));

			case TObject:
				StringIndexed(value, Std.string(value), Reflect.fields(value), false, propGet);

			case TClass(Array):
				var arr:Array<Dynamic> = cast value;
				IntIndexed(value, arr.length, arrayGet);

			case TClass(haxe.ds.StringMap):
				var map:haxe.ds.StringMap<Dynamic> = cast value;
				var keys = [for (k in map.keys()) '$k'];
				StringIndexed(value, Std.string(value), keys, true, stringMapGet);

			case TClass(haxe.ds.IntMap):
				var map:haxe.ds.IntMap<Dynamic> = cast value;
				var keys = [for (k in map.keys()) '$k'];
				StringIndexed(value, Std.string(value), keys, false, intMapGet);

			case TClass(c):
				var fields = getProps(c);
				var staticFields = [];
				var klass = Type.getClass(value);
				var className = "Unknown";
				if (klass != null) {
					var superKlass = Type.getSuperClass(klass);
					className = Type.getClassName(klass);
					if (klass != superKlass) {
						staticFields = getClassProps(c);
					}
					var dotIndex = className.lastIndexOf(".");
					if (dotIndex != -1) {
						className = className.substr(dotIndex + 1);
					}
				}
				var printedValue = className + ", " + Std.string(value);
				var all = fields.concat(staticFields);
				StringIndexed(value, printedValue, [
					for (f in all)
						if (!Reflect.isFunction(propStaticGet(c, value, f)))
							f
				], false, propStaticGet.bind(c));
		}
	}

	/** Throws a message for the user when `expression` can't be parsed or evaluated. **/
	public static function evaluate(parser:Parser, expression:String, threadId:Int, frameId:Int, ?context:FrameScope.FrameContext):Null<Variable> {
		var evalRes = execute(parser, initInterp(threadId, frameId, true, context), expression);
		return {
			name: expression,
			value: resolveValue(evalRes),
			type: getType(evalRes)
		};
	}

	/** The value of `expression` in `interp`. Throws a message for the user when it can't be parsed or evaluated. **/
	public static function execute(parser:Parser, interp:Interp, expression:String):Dynamic {
		try {
			return interp.execute(parser.parseString(expression));
		} catch (e:Error) {
			// hxcpp's `catch (e:Error)` also catches the values of other enums (hxcpp 4.3).
			if (Type.getEnum(e) != Error)
				throw e;
			throw errorMessage(e);
		}
	}

	/** A message for a value the evaluator threw. **/
	public static function describeError(error:Dynamic):String {
		return Type.getEnum(error) == Error ? errorMessage(error) : Std.string(error);
	}

	static function errorMessage(error:Error):String {
		return switch (error) {
			case EInvalidChar(c): 'Invalid character ${String.fromCharCode(c)}';
			case EUnexpected(s): 'Unexpected $s';
			case EUnterminatedString: "Unterminated string";
			case EUnterminatedComment: "Unterminated comment";
			case EInvalidPreprocessor(msg): 'Invalid preprocessor directive: $msg';
			case EUnknownVariable(v): 'Unknown identifier $v';
			case EInvalidIterator(v): 'Can\'t iterate over $v';
			case EInvalidOp(op): 'Unsupported operator $op';
			case EInvalidAccess(f): 'Can\'t access field $f';
			case ECustom(msg): msg;
		}
	}

	/** An interpreter for code in a stopped frame: its variables, and the names its code sees (`context`). **/
	public static function initInterp(threadId:Int, frameId:Int, exposeMembers:Bool = false, ?context:FrameScope.FrameContext):Interp {
		var stackVariables = cpp.vm.Debugger.getStackVariables(threadId, frameId, false);
		var interp = new Interp();
		FrameScope.apply(interp, context);
		if (context != null)
			interp.frameClass = Type.resolveClass(context.className);
		for (vName in stackVariables) {
			var value = cpp.vm.Debugger.getStackVariableValue(threadId, frameId, vName, false);
			var klass = Type.getClass(value);
			interp.variables.set(Type.getClassName(klass), klass);
			if (vName == "this")
				interp.thisValue = value;
			if (exposeMembers) {
				if (vName == "this") {
					var members = Reflect.fields(value);
					for (mName in members) {
						var mValue = propGet(value, mName);
						interp.variables.set(mName, mValue);
					}
				}
			}
			interp.variables.set(vName, value);
		}

		return interp;
	}

	static function getClassProps(c:Class<Dynamic>) {
		var fields = [];
		try {
			var sflds = Type.getClassFields(c);
			for (f in sflds) {
				fields.push('static $f');
			}
		} catch (e:Dynamic) {
			trace('error:$e');
		}
		return fields;
	}

	static function getProps(c:Class<Dynamic>) {
		var fields = [];
		try {
			var flds = Type.getInstanceFields(c);
			for (f in flds) {
				fields.push(f);
			}
		} catch (e:Dynamic) {
			trace('error:$e');
		}
		return fields;
	}

	public static function getType(value:Dynamic):String {
		return switch (Type.typeof(value)) {
			case TNull, TUnknown: "Unknown";
			case TInt: "Int";
			#if (haxe_ver >= 5)
			case TInt64: "Int64";
			#end
			case TFloat: "Float";
			case TBool: "Bool";
			case TFunction: "Function";
			case TEnum(e): Type.getEnumName(e);
			case TClass(String): "String";
			case TClass(Array): "Array";
			case TClass(c): getClassName(c);
			case TObject:
				Tools.isOfType(value, Class) ? getClassName(cast value) : "Anonymous";
		}
	}

	static function getClassName(klass:Class<Dynamic>):String {
		var className:String = "<unknown class name>";
		if (null != klass) {
			var klassName:String = Type.getClassName(klass);
			if (null != klassName && 0 != klassName.length) {
				className = klassName;
			}
		}
		return className;
	}

	public static function toString(varType:VarType):String {
		return "";
	}

	public static function arrayGet(value:Dynamic, index:Int):Dynamic {
		var arr:Array<Dynamic> = cast value;
		return arr[index];
	}

	public static function propGet(value:Dynamic, key:String):Dynamic {
		var propVal = null;
		try {
			propVal = Reflect.getProperty(value, key);
			if (propVal == null)
				propVal = Reflect.field(value, key);
		} catch (e:Dynamic) {
			trace(e);
		}
		return propVal;
	}

	public static function propStaticGet(klass:Class<Dynamic>, value:Dynamic, key:String):Dynamic {
		var propVal = null;
		try {
			var parts = key.split(" ");
			key = parts[parts.length - 1];
			propVal = Reflect.getProperty(klass, key);
			if (propVal == null) {
				propVal = propGet(value, key);
			}
		} catch (e:Dynamic) {
			trace(e);
		}
		return propVal;
	}

	public static function stringMapGet(value:Dynamic, key:String):Dynamic {
		var map:Map<String, Dynamic> = cast value;
		return map.get(key);
	}

	public static function intMapGet(value:Dynamic, key:String):Dynamic {
		var map:Map<Int, Dynamic> = cast value;
		return map.get(Std.parseInt(key));
	}
}
