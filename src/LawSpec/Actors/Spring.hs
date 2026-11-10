-- | Typed actors for Java and Kotlin on Apache Pekko through the Spring Boot
-- actor starter (lawspec.edn's `:actors {:runtime :spring}`). The generated
-- classes are the Pekko runtime's (LawSpec.Actors.Pekko), with the same
-- public surface, and each actor class also has a nested SpringActor
-- @Component: start spawns the actor through the starter's SpringActorSystem
-- as that component's actor (LawSpecSpring), so it runs in the Spring
-- application's actor system. Supervision is LawSpecPekkoSupervisor's OTP
-- emulation. Groovy and Clojure reuse the Java classes. The runtime's files
-- are written once beside the actors. ref:DEC-spring-actor-starter
-- ref:DEC-pekko-otp-supervision
module LawSpec.Actors.Spring (emit, runtimeFiles) where

import LawSpec.Actors.Jvm (Runtime(..), emitWith)
import qualified LawSpec.Actors.Pekko as Pekko
import LawSpec.Actors.Types (Actor, Supervision)
import LawSpec.Common (Artifact(..))
import qualified LawSpec.Core as C
import LawSpec.RuntimeSources (runtimeSource)

springRuntime :: Runtime
springRuntime = Pekko.pekkoRuntime
  { runtimeImports = runtimeImports Pekko.pekkoRuntime ++
      [ "io.github.seonwkim.actor.SpringActor", "io.github.seonwkim.actor.SpringActorBehavior"
      , "io.github.seonwkim.actor.SpringActorContext", "lawspec.runtime.spring.LawSpecSpring"
      , "org.springframework.stereotype.Component" ]
  , runtimeSpring = True
  }

emit :: String -> Bool -> Int -> [C.DataDeclaration] -> [Actor] -> [Supervision] -> Either String [Artifact]
emit target minify bits datas actors supervisions =
  (runtimeFiles ++) <$> emitWith springRuntime target minify bits datas actors supervisions

-- | The Pekko runtime's Java sources and LawSpecSpring.
runtimeFiles :: [Artifact]
runtimeFiles = Pekko.runtimeFiles ++
  [ Artifact "src/main/java/lawspec/runtime/spring/LawSpecSpring.java" (runtimeSource "java-spring") "generated" "source" ]
