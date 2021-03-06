module engine.core.logging.luainterface;

import std.exception : enforce;
import engine.core, engine.util;

void registerLoggingLibrary(ref LuaState state, string name)
{
    auto guard = LuaStackGuard(state, 0);

    auto funcs = 
    [
        luaL_Reg("log",        &luaCFunc!log),
        luaL_Reg("forceFlush", &luaCFunc!luaLogForceFlush),
        luaL_Reg(null, null)
    ];
    state.register(name, funcs);

    state.loadString(`
        local library = ...
        library.logTrace   = function(str) library.log(LogLevel.trace,   str, 2) end
        library.logDebug   = function(str) library.log(LogLevel.debug_,  str, 2) end
        library.logInfo    = function(str) library.log(LogLevel.info,    str, 2) end
        library.logWarning = function(str) library.log(LogLevel.warning, str, 2) end
        library.logError   = function(str) library.log(LogLevel.error,   str, 2) end
        library.logFatal   = function(str) library.log(LogLevel.fatal,   str, 2) end
    `).enforceOk;
    state.insert(-2);
    state.pcall(1, 0).enforceOk;
}

void loadLuaLoggingConfigFile(ref LuaState lua, string configFile)
{
    auto guard = LuaStackGuard(lua, 0);

    auto result = lua.loadFile(configFile);
    enforce(result.isOk, "Could not load logger config: "~result.error);

    result = lua.pcall(0, 1);
    enforce(result.isOk, "Could not execute logger config: "~result.error);
    enforce(lua.type(-1) == LUA_TTABLE, "Lua did not return a table.");

    lua.forEach(-1, (ref _)
    {
        // -1 is value. Value should be a table.
        enforce(lua.type(-1) == LUA_TTABLE, "Returned table can only contain other tables.");

        const type        = lua.rawGet!string(-1, "type").enforceOkValue;
        const minLogLevel = lua.rawGet!LogLevel(-1, "minLogLevel").enforceOkValue;
        const maxLogLevel = lua.rawGet!LogLevel(-1, "maxLogLevel").enforceOkValue;
        const style       = lua.rawGet!(LogMessageStyle, asUnchecked)(-1, "style").enforceOkValue;

        switch(type)
        {
            case "console":
                addConsoleLoggingSink(style, minLogLevel, maxLogLevel);
                break;

            case "file":
                const fileName = lua.rawGet!string(-1, "file").enforceOkValue;
                addFileLoggingSink(fileName, style, minLogLevel, maxLogLevel);
                break;

            default: throw new Exception("Unknown logger type: "~type);
        }
    });
    lua.pop(1);
}

private int log(ref LuaState lua)
{
    import std.string : fromStringz;
    import std.datetime : Clock;

    lua.checkType(1, LUA_TNUMBER);
    lua.checkType(2, LUA_TSTRING);

    LogMessage msg;
    msg.level = lua.as!LogLevel(1);
    msg.message = lua.as!string(2);

    auto result = lua.getDebugInfo("nlS", lua.getTop() > 2 ? lua.as!int(3) : 1);
    if(!result.isOk)
        return lua.error(result.error);

    auto dbg = result.value;
    msg.line      = dbg.currentline;
    msg.function_ = dbg.name.fromStringz.idup;
    msg.file      = dbg.short_src.ptr.fromStringz.idup;
    msg.timestamp = Clock.currTime;
    
    logRaw(msg);
    return 0;
}

private int luaLogForceFlush(ref LuaState _)
{
    logForceFlush();
    return 0;
}