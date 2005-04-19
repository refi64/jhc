{-------------------------------------------------------------------------------

        Copyright:              The Hatchet Team (see file Contributors)

        Module:                 DataConsAssump 

        Description:            Computes the type assumptions of data 
                                constructors in a module

                                For example:
                                        MyCons :: a -> MyList a
                                        Just :: a -> Maybe a
                                        True :: Bool

                                Note Well:

                                from section 4.2 of the Haskell Report:

                                "These declarations may only appear at the 
                                 top level of a module."

        Primary Authors:        Bernie Pope

        Notes:                  See the file License for license information

-------------------------------------------------------------------------------}

module DataConsAssump (dataConsEnv) where


import HsSyn  
import Representation     
import Type                     (assumpToPair, makeAssump, Types (..), quantify)
import TypeUtils                (aHsTypeToType)
import KindInfer 
import FrontEnd.Env              

--------------------------------------------------------------------------------

dataConsEnv :: Module -> KindEnv -> [HsDecl] -> Env Scheme 
dataConsEnv modName kt decls 
   = joinListEnvs $ map (dataDeclEnv modName kt) decls 


-- we should only apply this function to data decls and newtype decls
-- howver the fall through case is just there for completeness

dataDeclEnv :: Module -> KindEnv -> (HsDecl) -> Env Scheme 
dataDeclEnv modName kt (HsDataDecl _sloc context typeName args condecls _)
   = joinListEnvs $ map (conDeclType modName kt preds resultType) $ condecls 
   where
   typeKind = kindOf typeName kt 
   resultType = foldl TAp tycon argVars
   tycon = TCon (Tycon typeName typeKind)
   argVars = map fromHsNameToTyVar $ zip argKinds args
   argKinds = init $ unfoldKind typeKind 
   fromHsNameToTyVar :: (Kind, HsName) -> Type
   fromHsNameToTyVar (k, n) 
      = TVar (tyvar n k)
   preds = hsContextToPreds kt context

dataDeclEnv modName kt (HsNewTypeDecl _sloc context typeName args condecl _)
   = conDeclType modName kt preds resultType condecl
   where
   typeKind = kindOf typeName kt
   resultType = foldl TAp tycon argVars
   tycon = TCon (Tycon typeName typeKind)
   argVars = map fromHsNameToTyVar $ zip argKinds args
   argKinds = init $ unfoldKind typeKind
   fromHsNameToTyVar :: (Kind, HsName) -> Type
   fromHsNameToTyVar (k, n)
      = TVar (tyvar n k)
   preds = hsContextToPreds kt context

dataDeclEnv _modName _kt _anyOtherDecl 
   = emptyEnv


hsContextToPreds :: KindEnv -> HsContext -> [Pred]
hsContextToPreds kt assts = map (hsAsstToPred kt) assts

conDeclType :: Module -> KindEnv -> [Pred] -> Type -> HsConDecl -> Env Scheme 
conDeclType modName kt preds tResult (HsConDecl _sloc conName bangTypes)
   = unitEnv $ assumpToPair $ makeAssump conName $ quantify (tv qualConType) qualConType
   where
   conType = foldr fn tResult (map (bangTypeToType kt) bangTypes)
   qualConType = preds :=> conType
conDeclType modName kt preds tResult rd@(HsRecDecl _sloc conName _)
   = unitEnv $ assumpToPair $ makeAssump conName $ quantify (tv qualConType) qualConType
   where
   conType = foldr fn tResult (map (bangTypeToType kt) (hsConDeclArgs rd))
   qualConType = preds :=> conType

bangTypeToType :: KindEnv -> HsBangType -> Type
bangTypeToType kt (HsBangedTy t) = aHsTypeToType kt t 
bangTypeToType kt (HsUnBangedTy t) = aHsTypeToType kt t

