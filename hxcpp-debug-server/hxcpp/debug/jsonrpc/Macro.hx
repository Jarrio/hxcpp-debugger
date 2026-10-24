package hxcpp.debug.jsonrpc;

import haxe.macro.Context;
import haxe.macro.Compiler;

class Macro {
	macro public static function injectServer():Void {
		if (Context.defined("cpp") && Context.defined("debug")) {
			#if (haxe >= version("4.3.0"))
			Context.onAfterInitMacros(() -> {
				Context.getType("hxcpp.debug.jsonrpc.Server");
			});
			#else
			Context.getType("hxcpp.debug.jsonrpc.Server");
			#end
			Compiler.define("HXCPP_DEBUGGER");
		}
	}

	macro public static function getDefinedValue(key:String, defaultV) {
		var val = Context.definedValue(key);
		return (val == null) ? macro ${defaultV} : macro $v{val};
	}
}
