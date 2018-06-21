{-# LANGUAGE CPP #-}

-- | Wrappers around functions from pvss-haskell which implement a
-- Verifiable Secret Sharing (VSS) algorithm called Scrape.
--
-- For more details see <https://github.com/input-output-hk/pvss-haskell>.

module Pos.Crypto.SecretSharing
       ( -- * Keys and related.
         VssPublicKey (..)
       , VssKeyPair (..)
       , toVssPublicKey
       , vssKeyGen
       , deterministicVssKeyGen

         -- * Sharing
       , Scrape.DhSecret (..)
       , EncShare (..)
       , Secret (..)
       , SecretProof (..)
       , DecShare (..)
       , Scrape.Threshold

       , decryptShare
       , getDhSecret
       , genSharedSecret
       , recoverSecret
       , secretToDhSecret
       , verifyEncShares
       , verifyDecShare
       , verifySecret

       , testScrape
       ) where

import           Universum

import           Crypto.Random (MonadRandom)
import qualified Crypto.SCRAPE as Scrape
import qualified Data.Binary as Binary
import qualified Data.ByteString as BS
import           Data.Coerce (coerce)
import           Data.Hashable (Hashable (hashWithSalt))
import           Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import           Data.List (zipWith3)
import qualified Data.List.NonEmpty as NE
import           Data.SafeCopy (SafeCopy (..))
import           Data.Text.Buildable (Buildable)
import qualified Data.Text.Buildable as Buildable
import           Formatting (bprint, int, sformat, stext, (%))

import           Pos.Binary.Class (AsBinary (..), AsBinaryClass (..), Bi (..),
                     Cons (..), Field (..), cborError, decodeFull',
                     deriveSimpleBi, serialize')
import           Pos.Crypto.Hashing (hash, shortHashF)
import           Pos.Crypto.Orphans ()
import           Pos.Crypto.Random (deterministic)

----------------------------------------------------------------------------
-- Keys
----------------------------------------------------------------------------

-- | This key is used as public key in VSS.
newtype VssPublicKey = VssPublicKey
    { getVssPublicKey :: Scrape.PublicKey
    } deriving (Show, Eq, Binary.Binary)

-- | Note: this is an important instance, don't change it! It dictates the
-- order of participants when generating a commitment.
instance Ord VssPublicKey where
    compare = comparing Binary.encode

instance Hashable VssPublicKey where
    hashWithSalt s = hashWithSalt s . Binary.encode

deriving instance Bi VssPublicKey

-- | This key pair is used to decrypt share generated by VSS.
newtype VssKeyPair =
    VssKeyPair Scrape.KeyPair
    deriving (Show, Eq, Generic)

instance Buildable VssKeyPair where
    build = bprint ("vsssec:"%shortHashF) . hash

deriving instance Bi VssKeyPair

-- | Extract VssPublicKey from VssKeyPair.
toVssPublicKey :: VssKeyPair -> VssPublicKey
toVssPublicKey (VssKeyPair pair) = VssPublicKey $ Scrape.toPublicKey pair

-- | Generate a VssKeyPair. It's recommended to run it with
-- 'runSecureRandom' from "Pos.Crypto.Random" because the OpenSSL generator
-- is probably safer than the default IO generator.
vssKeyGen :: MonadRandom m => m VssKeyPair
vssKeyGen = VssKeyPair <$> Scrape.keyPairGenerate

-- | Generate VssKeyPair using given seed. The length of the seed doesn't
-- matter.
deterministicVssKeyGen :: ByteString -> VssKeyPair
deterministicVssKeyGen seed = deterministic seed vssKeyGen

----------------------------------------------------------------------------
-- Types
----------------------------------------------------------------------------

-- | Secret can be generated by 'genSharedSecret' function along with shares.
newtype Secret = Secret
    { getSecret :: Scrape.Secret
    } deriving (Show, Eq)

deriving instance Bi Secret

-- | Shares can be used to reconstruct 'Secret'.
newtype DecShare = DecShare
    { getDecShare :: Scrape.DecryptedShare
    } deriving (Show, Eq)

deriving instance Bi DecShare

-- | Encrypted share which needs to be decrypted using 'VssKeyPair' first.
newtype EncShare = EncShare
    { getEncShareVal :: Scrape.EncryptedSi
    } deriving (Show, Eq)

deriving instance Bi EncShare

-- | This extra data may be used to verify various stuff.
data SecretProof = SecretProof
    { spExtraGen       :: !Scrape.ExtraGen
    , spProof          :: !Scrape.Proof
    , spParallelProofs :: !Scrape.ParallelProofs
    , spCommitments    :: ![Scrape.Commitment]
    } deriving (Show, Eq, Generic)

instance NFData SecretProof

instance Bi SecretProof =>
         Hashable SecretProof where
    hashWithSalt s = hashWithSalt s . serialize'

deriveSimpleBi ''SecretProof [
    Cons 'SecretProof [
        Field [| spExtraGen       :: Scrape.ExtraGen       |],
        Field [| spProof          :: Scrape.Proof          |],
        Field [| spParallelProofs :: Scrape.ParallelProofs |],
        Field [| spCommitments    :: [Scrape.Commitment]   |]
    ]
  ]

instance Bi SecretProof => SafeCopy SecretProof where
    getCopy = getCopyBi
    putCopy = putCopyBi

----------------------------------------------------------------------------
-- Functions
----------------------------------------------------------------------------

-- | Extract ByteString from DhSecret.
getDhSecret :: Scrape.DhSecret -> ByteString
getDhSecret (Scrape.DhSecret s) = s

-- | Transform a Secret into a usable random value.
secretToDhSecret :: Secret -> Scrape.DhSecret
secretToDhSecret = Scrape.secretToDhSecret . getSecret

-- | Decrypt share using secret key. Doesn't verify if an encrypted
-- share is valid, for this you need to use 'verifyEncShares'.
decryptShare
    :: MonadRandom m
    => VssKeyPair -> EncShare -> m DecShare
decryptShare (VssKeyPair k) (EncShare encShare) =
    DecShare <$> Scrape.shareDecrypt k encShare

-- | Generate random secret using MonadRandom and share it between given
-- public keys. The shares will be given in the order of *sorted* keys, not
-- the original order.
genSharedSecret
    :: MonadRandom m
    => Scrape.Threshold
    -> NonEmpty VssPublicKey
    -> m (Secret, SecretProof, [(VssPublicKey, EncShare)])
genSharedSecret t ps
    | t <= 1     = error "genSharedSecret: threshold must be > 1"
    | t >= n - 1 = error "genSharedSecret: threshold must be < n-1"
    | otherwise  = convertRes <$> Scrape.escrow t (coerce sorted)
  where
    n = fromIntegral (length ps)
    sorted = sort (toList ps)
    convertRes (gen, secret, shares, comms, proof, pproofs) =
        (coerce secret,
         SecretProof gen proof pproofs comms,
         zip sorted (coerce shares))

-- | Recover secret if there are enough correct shares.
--
-- You *must* perform these checks on earlier stages:
--
--   * There are as many decrypted shares as there are encrypted shares for
--     each participant.
--
--   * All shares are decrypted correctly (use 'verifyDecShare' for that)
--
recoverSecret
    :: Scrape.Threshold
    -> [(VssPublicKey, Int)]            -- ^ Participants + how many shares
                                        --    were sent to each
    -> HashMap VssPublicKey [DecShare]  -- ^ Shares decrypted and returned by
                                        --    some participants
    -> Maybe Secret
recoverSecret (fromIntegral -> thr) (sortWith fst -> participants) shares = do
    -- We reorder the shares so that 'recover' can consume them
    let ordered :: [(Scrape.ShareId, DecShare)]
        ordered = reorderDecryptedShares participants shares
    -- Then we check that we have enough shares and do secret recovery
    guard (length ordered >= thr)
    pure (coerce Scrape.recover (take thr ordered))

-- | Like 'Scrape.reorderDecryptedShares', but handles the case when multiple
-- shares were created for a single key.
--
-- TODO: move to pvss-haskell, maybe
--
-- __Description of the algorithm__
--
-- We know:
--   * the /original/ order of participants
--   * how many shares were generated for each participant
--   * a list of decrypted shares for each participant,
--     though some participants might be missing
--
-- /Note:/ we assume that if a participant isn't missing then their shares
-- are present in the right order and no shares are skipped. This is a valid
-- assumption to make because
--   * first we verify encrypted shares with 'verifyEncShares'
--     (this takes care of the order and count of shares)
--   * then we verify each decrypted share with 'verifyDecShare' against
--     the corresponding encrypted share
--   * and we don't forget to check that the counts of encrypted and
--     decrypted shares match.
--
-- After this is done, we 'go' through the list of participants and try to
-- recover a share with index 'i' for each 'i', starting from 1 (not 0). If
-- we have 'n' shares for some participant 'k', we can recover shares with
-- indices @[i..i+n-1]@, so we add them to the list and continue from index
-- @i+n@. If we don't have the shares for the participant, we just skip 'n'
-- shares and move to the next participant and try to find the @i+n@'th
-- share.
reorderDecryptedShares
    :: [(VssPublicKey, Int)]            -- ^ Participants + how many shares
                                        --    were sent to each
    -> HashMap VssPublicKey [DecShare]  -- ^ Decrypted shares
    -> [(Scrape.ShareId, DecShare)]
reorderDecryptedShares participants shares =
    map (first toInteger) $ go 1 participants
  where
    go :: Int                        -- ^ Index of current share
       -> [(VssPublicKey, Int)]      -- ^ Remaining participants
       -> [(Int, DecShare)]
    go _ []         = []
    go i ((k,n):ps) = case HM.lookup k shares of
        Nothing -> go (i + n) ps
        Just ss -> zip [i..] (take n ss) ++ go (i + n) ps

-- CHECK: @verifyEncShare
-- | Verify encrypted shares
verifyEncShares
    :: MonadRandom m
    => SecretProof
    -> Scrape.Threshold
    -> [(VssPublicKey, EncShare)]
    -> m Bool
verifyEncShares SecretProof{..} threshold (sortWith fst -> pairs)
    | threshold <= 1     = error "verifyEncShares: threshold must be > 1"
    | threshold >= n - 1 = error "verifyEncShares: threshold must be < n-1"
    | otherwise =
          Scrape.verifyEncryptedShares
              spExtraGen
              threshold
              spCommitments
              spParallelProofs
              (coerce $ map snd pairs)  -- shares
              (coerce $ map fst pairs)  -- participants
  where
    n = fromIntegral (length pairs)

-- CHECK: @verifyShare
-- | Verify that DecShare has been decrypted correctly.
verifyDecShare :: VssPublicKey -> EncShare -> DecShare -> Bool
verifyDecShare (VssPublicKey pk) (EncShare es) (DecShare sh) =
    Scrape.verifyDecryptedShare (es, pk, sh)

-- CHECK: @verifySecretProof
-- | Verify that SecretProof corresponds to Secret.
verifySecret :: Scrape.Threshold -> SecretProof -> Secret -> Bool
verifySecret thr SecretProof{..} (Secret secret) =
    Scrape.verifySecret spExtraGen thr spCommitments secret spProof

----------------------------------------------------------------------------
-- Test
----------------------------------------------------------------------------

-- | You can use this to do debugging. If everything is okay with SCRAPE, it
-- will print 'True's.
testScrape
    :: (MonadRandom m, MonadIO m)
    => Int           -- ^ Threshold (number of participants = 2× threshold)
    -> m ()
testScrape t = do
    let thr :: Scrape.Threshold
        thr = fromIntegral t
    -- Generate t*2 keys.
    vsskeys <- sortWith toVssPublicKey <$> replicateM (t*2) vssKeyGen
    let pks = map toVssPublicKey vsskeys
    -- Generate and share a secret.
    (secret, proof, encShares) <- genSharedSecret thr (NE.fromList pks)
    -- Decrypt the shares.
    decShares <- zipWithM decryptShare vsskeys (map snd encShares)
    -- Recover the secret.
    let recovered = recoverSecret thr
            (map (,1) pks)
            (HM.fromList (zip pks (map one decShares)))
    -- Now do checks:
    print =<< verifyEncShares proof thr encShares
    print (zipWith3 verifyDecShare pks (map snd encShares) decShares)
    print (verifySecret thr proof secret)
    print (Just secret == recovered)

----------------------------------------------------------------------------
-- SecretSharing AsBinary
----------------------------------------------------------------------------

vssPublicKeyBytes, secretBytes, decShareBytes, encShareBytes :: Int
vssPublicKeyBytes = 35   -- 33 data + 2 of CBOR overhead
secretBytes       = 35   -- 33 data + 2 of CBOR overhead
decShareBytes     = 99   -- Point (33) + DLEQ.Proof (64) + CBOR overhead (2)
encShareBytes     = 35   -- 33 data + 2 of CBOR overhead

-- !A note about these instances! --
--
-- For most of the secret sharing types the only check we do during
-- deserialization is length check. As long as length matches our
-- expectations, the decoding succeeds (look at 'Binary' instances in
-- 'pvss') which in turn means that we can use 'fromBinary' and be quite
-- sure it will succeed. That's why it's important to check length here
-- (this check is cheap, so it's good to do it as soon as possible).
-- 'SecretProof' used to be an exception, but currently we don't use
-- 'AsBinary' for 'SecretProof' (we might in the future); this said, it's
-- alright to use 'AsBinary' for variable-length things as long as you're
-- careful.
--
#define BiMacro(B, BYTES) \
  instance Bi (AsBinary B) where {\
    encode (AsBinary bs) = encode bs ;\
    decode = do { bs <- decode \
                ; when (BYTES /= length bs) (cborError "AsBinary B: length mismatch!") \
                ; return (AsBinary bs) } }; \

BiMacro(VssPublicKey, vssPublicKeyBytes)
BiMacro(Secret, secretBytes)
BiMacro(DecShare, decShareBytes)
BiMacro(EncShare, encShareBytes)

checkLen :: Text -> Text -> Int -> ByteString -> ByteString
checkLen action name len bs =
    maybe bs error $ checkLenImpl action name len $ BS.length bs

checkLenImpl :: Integral a => Text -> Text -> a -> a -> Maybe Text
checkLenImpl action name expectedLen len
    | expectedLen == len = Nothing
    | otherwise =
        Just $
        sformat
            (stext % " " %stext % " failed: length of bytestring is " %int %
             " instead of " %int)
            action
            name
            len
            expectedLen

#define Ser(B, Bytes, Name) \
  instance AsBinaryClass B where {\
    asBinary = AsBinary . checkLen "asBinary" Name Bytes . serialize' ;\
    fromBinary = decodeFull' . checkLen "fromBinary" Name Bytes . getAsBinary }; \

Ser(VssPublicKey, vssPublicKeyBytes, "VssPublicKey")
Ser(Secret, secretBytes, "Secret")
Ser(DecShare, decShareBytes, "DecShare")
Ser(EncShare, encShareBytes, "EncShare")

instance Buildable (AsBinary Secret) where
    build _ = "secret \\_(o.o)_/"

instance Buildable (AsBinary DecShare) where
    build _ = "share \\_(*.*)_/"

instance Buildable (AsBinary EncShare) where
    build _ = "encrypted share \\_(0.0)_/"

instance Buildable (AsBinary VssPublicKey) where
    build = bprint ("vsspub:"%shortHashF) . hash
