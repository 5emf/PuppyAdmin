use mlua::{Lua, Result, Value, Table};
use std::io::Write;
fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let lua = unsafe { Lua::unsafe_new() };
    let g = lua.globals();
    g.set("host_load", lua.create_function(|lua, (src, name, env): (mlua::String, Option<String>, Option<Table>)| {
        let mut c = lua.load(src.as_bytes().to_vec()).set_name(name.unwrap_or("=chunk".into()));
        if let Some(e) = env { c = c.set_environment(e); }
        match c.into_function() { Ok(f) => Ok((Value::Function(f), Value::Nil)), Err(e) => Ok((Value::Nil, Value::String(lua.create_string(e.to_string())?))) }
    })?)?;
    g.set("host_read", lua.create_function(|lua, p: String| { Ok(lua.create_string(std::fs::read(p).map_err(mlua::Error::external)?)?) })?)?;
    g.set("host_write", lua.create_function(|_, (p, s): (String, mlua::String)| { std::fs::write(p, s.as_bytes().to_vec()).map_err(mlua::Error::external) })?)?;
    g.set("host_append", lua.create_function(|_, (p, s): (String, mlua::String)| { let mut f = std::fs::OpenOptions::new().create(true).append(true).open(p).map_err(mlua::Error::external)?; f.write_all(&s.as_bytes()).map_err(mlua::Error::external) })?)?;
    g.set("host_args", args[2..].to_vec())?;
    let _ = lua.set_memory_limit(1_500_000_000);
    g.set("host_deadline", lua.create_function(|lua, secs: f64| {
        let start = std::time::Instant::now();
        let fired = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        lua.set_interrupt(move |_| {
            if !fired.load(std::sync::atomic::Ordering::SeqCst) && start.elapsed().as_secs_f64() > secs {
                fired.store(true, std::sync::atomic::Ordering::SeqCst);
                Err(mlua::Error::runtime("HOST_DEADLINE"))
            } else { Ok(mlua::VmState::Continue) }
        });
        Ok(())
    })?)?;
    let src = std::fs::read(&args[1]).map_err(mlua::Error::external)?;
    if let Err(e) = lua.load(src).set_name(format!("@{}", args[1])).exec() { eprintln!("ERROR: {}", e); std::process::exit(1); }
    Ok(())
}
