module Explorer.State where

import Prelude
import DOM.Node.Types (ElementId(..))
import Data.DateTime.Instant (instant, toDateTime)
import Data.Maybe (Maybe(..), fromJust)
import Data.Time.Duration (Milliseconds(..))
import Data.Tuple (Tuple(..))
import Explorer.Api.Types (SocketSubscription, SocketSubscriptionData)
import Explorer.I18n.Lang (Language(..), translate)
import Explorer.I18n.Lenses (common, cTitle) as I18nL
import Explorer.Routes (Route(..))
import Explorer.Types.State (DashboardAPICode(..), Search(..), SearchEpochSlotQuery, State, SocketSubscriptionItem(..))
import Explorer.Util.Config (SyncAction(..))
import Explorer.Util.Factory (mkCAddress)
import Network.RemoteData (RemoteData(..))
import Partial.Unsafe (unsafePartial)

initialState :: State
initialState =
    { lang: English
    , route: Dashboard
    , socket:
        { connected: false
        , connection: Nothing
        , subscriptions: []
        }
    , syncAction: SyncBySocket
    -- , syncAction: SyncByPolling
    , viewStates:
        { globalViewState:
            { gViewMobileMenuOpenend: false
            , gViewTitle: translate (I18nL.common <<< I18nL.cTitle) English
            , gViewSearchInputFocused: false
            , gViewSelectedSearch: SearchAddress
            , gViewSearchQuery: emptySearchQuery
            , gViewSearchTimeQuery: emptySearchTimeQuery
            }
        ,  dashboard:
            { dbViewBlocksExpanded: false
            , dbViewBlockPagination: minPagination
            , dbViewNextBlockPagination: minPagination
            , dbViewLoadingBlockPagination: false
            , dbViewLoadingTotalBlocks: false
            , dbViewBlockPaginationEditable: false
            , dbViewTxsExpanded: false
            , dbViewSelectedApiCode: Curl
            }
        , addressDetail:
            { addressTxPagination: minPagination
            , addressTxPaginationEditable: false
            }
        , blockDetail:
            { blockTxPagination: minPagination
            , blockTxPaginationEditable: false
            }
        , blocksViewState:
            { blsViewPagination: minPagination
            , blsViewPaginationEditable: false
            }
        }
    , latestBlocks: NotAsked
    , totalBlocks: NotAsked
    , currentBlockSummary: NotAsked
    , currentBlockTxs: NotAsked
    , latestTransactions: NotAsked
    , currentTxSummary: NotAsked
    , currentCAddress: mkCAddress ""
    , currentAddressSummary: NotAsked
    , currentBlocksResult: NotAsked
    , errors: []
    , loading: false
    , now: toDateTime $ unsafePartial $ fromJust $ instant $ Milliseconds 0.0
    }

-- all constants are following here:

emptySearchQuery :: String
emptySearchQuery = ""

emptySearchTimeQuery :: SearchEpochSlotQuery
emptySearchTimeQuery = Tuple Nothing Nothing

maxSlotInEpoch :: Int
maxSlotInEpoch = 21600

minPagination :: Int
minPagination = 1 -- Note: We do start with 1 (not 0)

addressQRImageId :: String
addressQRImageId = "qr_image_id"

searchContainerId :: ElementId
searchContainerId = ElementId "explorer-search__container-id"

mkSocketSubscriptionItem :: SocketSubscription -> SocketSubscriptionData -> SocketSubscriptionItem
mkSocketSubscriptionItem socketSub socketSubData = SocketSubscriptionItem
    { socketSub
    , socketSubData
    }
