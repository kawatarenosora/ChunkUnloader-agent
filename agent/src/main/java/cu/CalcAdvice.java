package cu;

import net.bytebuddy.asm.Advice;

/**
 * Hooks CalcChunkWidth exit (boot/display-init point) so the requested grid
 * wins no matter when the engine computes it. Former ZB @Patch exit;
 * ByteBuddy edition, premain-registered (earlier and safer than mod-load).
 * References only cu.* (never the instrumented type itself).
 */
public final class CalcAdvice {

    private CalcAdvice() {
    }

    @Advice.OnMethodExit
    public static void exit() {
        try {
            CUControl.applyPending();
        } catch (Throwable ignored) {
        }
    }
}
