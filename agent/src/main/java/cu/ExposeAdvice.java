package cu;

import net.bytebuddy.asm.Advice;

/**
 * Runs on {@code LuaManager$Exposer.exposeAll} exit.
 * Body calls only cu.* (never the instrumented type itself;
 * PZ-alloy v1.2 LinkageError lesson). All game access lives in
 * {@link ExposeHook} behind reflection.
 */
public final class ExposeAdvice {

    private ExposeAdvice() {
    }

    @Advice.OnMethodExit
    public static void exit() {
        try {
            ExposeHook.register();
        } catch (Throwable ignored) {
        }
    }
}
