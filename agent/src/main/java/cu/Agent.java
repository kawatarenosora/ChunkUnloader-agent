package cu;

import java.lang.instrument.Instrumentation;
import java.util.Properties;
import net.bytebuddy.agent.builder.AgentBuilder;
import net.bytebuddy.asm.Advice;
import net.bytebuddy.description.type.TypeDescription;
import net.bytebuddy.dynamic.DynamicType;
import net.bytebuddy.matcher.ElementMatchers;
import net.bytebuddy.utility.JavaModule;

/**
 * ChunkUnloader javaagent (ZombieBuddy-free).
 * Two isolated hooks, each failure-contained so the game always continues:
 * (1) {@code LuaManager$Exposer.exposeAll} exit publishes cu.CUControl to
 * vanilla Lua; (2) {@code IsoChunkMap.CalcChunkWidth} exit re-applies the
 * pending grid at the sanctioned boot point (former ZB @Patch).
 * Premain registration runs before game classes load, earlier and safer
 * than mod-load-time patching.
 */
public class Agent {

    static final String REV = readRev();

    public static void premain(String args, Instrumentation inst) {
        if (args == null) {
            args = "";
        }
        boolean en = true;
        if (args.contains("enabled=false") || args.contains("disabled")) {
            en = false;
        }
        if ("false".equalsIgnoreCase(System.getProperty("cu.enabled", "true"))) {
            en = false;
        }
        System.out.println("[CU-Agent] loaded rev=" + REV + " enabled=" + en
                + (args.isEmpty() ? "" : " args=" + args));
        if (!en) {
            return;
        }
        StringBuilder done = new StringBuilder();
        try {
            new AgentBuilder.Default()
                    .with(new LogListener())
                    .type(ElementMatchers.named("zombie.Lua.LuaManager$Exposer"))
                    .transform((b, td, cl, m, pd) -> b.visit(
                            Advice.to(ExposeAdvice.class).on(
                                    ElementMatchers.named("exposeAll"))))
                    .installOn(inst);
            done.append("LuaManager$Exposer,");
        } catch (Throwable t) {
            System.err.println("[CU-Agent] failed zombie.Lua.LuaManager$Exposer: " + t);
        }
        try {
            new AgentBuilder.Default()
                    .with(new LogListener())
                    .type(ElementMatchers.named("zombie.iso.IsoChunkMap"))
                    .transform((b, td, cl, m, pd) -> b.visit(
                            Advice.to(CalcAdvice.class).on(
                                    ElementMatchers.named("CalcChunkWidth"))))
                    .installOn(inst);
            done.append("IsoChunkMap,");
        } catch (Throwable t) {
            System.err.println("[CU-Agent] failed zombie.iso.IsoChunkMap: " + t);
        }
        System.out.println("[CU-Agent] transformer registered targets=" + done);
    }

    static final class LogListener extends AgentBuilder.Listener.Adapter {
        @Override
        public void onTransformation(TypeDescription td, ClassLoader cl,
                JavaModule m, boolean loaded, DynamicType dt) {
            System.out.println("[CU-Agent] Transformed " + td.getName());
        }

        @Override
        public void onError(String name, ClassLoader cl,
                JavaModule m, boolean loaded, Throwable t) {
            System.err.println("[CU-Agent] failed " + name + ": " + t);
        }
    }

    static String readRev() {
        try {
            Properties p = new Properties();
            try (java.io.InputStream in =
                         Agent.class.getResourceAsStream("/cu/build-info.properties")) {
                if (in == null) {
                    return "unversioned";
                }
                p.load(in);
            }
            String r = p.getProperty("revision", "unversioned");
            return r != null ? r.trim() : "unversioned";
        } catch (Throwable t) {
            return "unversioned";
        }
    }
}
