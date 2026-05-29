{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
-- 1.1.0.0 will be enabled in conway
{-# OPTIONS_GHC -fobject-code -fno-ignore-interface-pragmas -fno-omit-interface-pragmas -fplugin-opt PlutusTx.Plugin:target-version=1.1.0.0 #-}
{-# OPTIONS_GHC -fplugin-opt PlutusTx.Plugin:defer-errors #-}

-- | Scripts used for testing
module Scripts (
  pingPongValidatorScript,
  PingPong.PingPongRedeemer (..),
  PingPong.PingPongState (..),
) where

import Cardano.Api qualified as C
import Convex.PlutusTx (compiledCodeToScript)
import PlutusTx (BuiltinData, CompiledCode)
import PlutusTx qualified
import PlutusTx.Prelude (BuiltinUnit)
import Scripts.PingPong qualified as PingPong

pingPongValidatorCompiled :: CompiledCode (BuiltinData -> BuiltinUnit)
pingPongValidatorCompiled = $$(PlutusTx.compile [||PingPong.validator||])

pingPongValidatorScript :: C.PlutusScript C.PlutusScriptV3
pingPongValidatorScript = compiledCodeToScript pingPongValidatorCompiled

plutusScript :: (C.IsPlutusScriptLanguage lang) => C.PlutusScript lang -> C.Script lang
plutusScript = C.PlutusScript C.plutusScriptVersion
