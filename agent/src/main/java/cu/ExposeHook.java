package cu;

import java.lang.reflect.Method;
import java.lang.reflect.Type;

/**
 * Vanilla-Lua publication of {@link CUControl}, reflection-only so the
 * agent never statically links game or Kahlua classes for this path
 * (version-proof; any API drift ends in a logged no-bridge instead of
 * a crash). Mirrors bu.ExposeHook.
 *
 * Vanilla {@code exposeLikeJavaRecursively} publishes under the package
 * path ({@code cu.CUControl}), while CU Lua historically uses the global
 * {@code CUControl} that ZombieBuddy provided. Both are wired: the
 * package table first, then a top-level alias.
 */
public final class ExposeHook {

    private ExposeHook() {
    }

    public static void register() {
        try {
            Class<?> lm = Class.forName("zombie.Lua.LuaManager");
            Object exposer = lm.getField("exposer").get(null);
            Object env = lm.getField("env").get(null);
            if (exposer == null || env == null) {
                System.err.println("[CU-Agent] failed: LuaManager.exposer/env is null");
                return;
            }
            exposer.getClass().getMethod("setExposed", Class.class)
                    .invoke(exposer, CUControl.class);
            Method expose = exposer.getClass().getMethod(
                    "exposeLikeJavaRecursively", Type.class, rawTableClass());
            expose.invoke(exposer, CUControl.class, env);
            aliasTopLevel(env);
            System.out.println("[CU-Agent] exposed cu.CUControl (+CUControl alias)");
        } catch (Throwable t) {
            System.err.println("[CU-Agent] failed to expose CUControl: " + t);
        }
    }

    /** Top-level {@code CUControl} alias so existing Lua keeps working. */
    private static void aliasTopLevel(Object env) {
        try {
            Method rawget = env.getClass().getMethod("rawget", Object.class);
            Method rawset = env.getClass().getMethod("rawset", Object.class, Object.class);
            Object ns = rawget.invoke(env, "cu");
            if (ns == null) {
                return;
            }
            Object ctrl = rawget.invoke(ns, "CUControl");
            if (ctrl == null) {
                return;
            }
            rawset.invoke(env, "CUControl", ctrl);
        } catch (Throwable t) {
            System.err.println("[CU-Agent] failed to alias CUControl: " + t);
        }
    }

    private static Class<?> rawTableClass() throws ClassNotFoundException {
        return Class.forName("se.krka.kahlua.vm.KahluaTable");
    }
}
