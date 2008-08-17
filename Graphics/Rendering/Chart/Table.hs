module Graphics.Rendering.Chart.Table (
    Table,
    tval, tspan,
    empty, nullt,
    (.|.), (./.),
    above, aboveN,
    beside, besideN,
    overlay,
    width, height,
    renderTable,
    weights
) where

import Data.List
import Data.Array
-- import qualified Data.Map as Map
import Control.Monad
import Numeric
import Graphics.Rendering.Chart.Renderable
import Graphics.Rendering.Chart.Types
--import Graphics.Rendering.Chart.Gtk
import qualified Graphics.Rendering.Cairo as C
import Debug.Trace

type Span = (Int,Int)
type Size = (Int,Int)
type SpaceWeight = (Double,Double)

type Cell a = (a,Span,SpaceWeight)

data Table a = Value (a,Span,SpaceWeight)
             | Above (Table a) (Table a) Size 
             | Beside (Table a) (Table a) Size
             | Overlay (Table a) (Table a) Size
	     | Empty
	     | Null
   deriving (Show)

width :: Table a -> Int
width Null = 0
width Empty = 1
width (Value _) = 1
width (Beside _ _ (w,h)) = w
width (Above _ _ (w,h)) = w
width (Overlay _ _ (w,h)) = w

height :: Table a -> Int
height Null = 0
height Empty = 1
height (Value _) = 1
height (Beside _ _ (w,h)) = h
height (Above _ _ (w,h)) = h
height (Overlay _ _ (w,h)) = h

tval :: a -> Table a
tval a = Value (a,(1,1),(0,0))

tspan :: a -> Span -> Table a
tspan a span = Value (a,span,(1,1))

empty, nullt :: Table a
empty = Empty
nullt = Null

above, beside :: Table a -> Table a -> Table a
above Null t = t
above t Null = t
above t1 t2 = Above t1 t2 size
  where size = (max (width t1) (width t2), height t1 + height t2)
	      
beside Null t = t
beside t Null = t
beside t1 t2 = Beside t1 t2 size
  where size = (width t1 + width t2, max (height t1) (height t2))

aboveN, besideN :: [Table a] -> Table a
aboveN = foldl above nullt
besideN = foldl beside nullt

overlay Null t = t
overlay t Null = t
overlay t1 t2 = Overlay t1 t2 size
  where size = (max (width t1) (width t2), max (height t1) (height t2))

(.|.) = beside
(./.) = above

weights :: SpaceWeight -> Table a -> Table a
weights sw Null = Null
weights sw Empty = Empty
weights sw (Value (v,sp,_)) = Value (v,sp,sw)
weights sw (Above t1 t2 sz) = Above (weights sw t1) (weights sw t2) sz
weights sw (Beside t1 t2 sz) = Beside (weights sw t1) (weights sw t2) sz
weights sw (Overlay t1 t2 sz) = Overlay (weights sw t1) (weights sw t2) sz

-- fix me, need to make .|. and .||. higher precedence
-- than ./. and .//.

instance Functor Table where
    fmap f (Value (a,span,ew)) = Value (f a,span,ew)
    fmap f (Above t1 t2 s) = Above (fmap f t1) (fmap f t2) s
    fmap f (Beside t1 t2 s) = Beside (fmap f t1) (fmap f t2) s
    fmap f (Overlay t1 t2 s) = Overlay (fmap f t1) (fmap f t2) s
    fmap f Empty = Empty
    fmap f Null = Null

mapTableM :: Monad m => (a -> m b) -> Table a -> m (Table b)
mapTableM f (Value (a,span,ew)) = do 
    b <- f a
    return (Value (b,span,ew))
mapTableM f (Above t1 t2 s) = do
    t1' <- mapTableM f t1
    t2' <- mapTableM f t2
    return (Above t1' t2' s)
mapTableM f (Beside t1 t2 s) = do
    t1' <- mapTableM f t1
    t2' <- mapTableM f t2
    return (Beside t1' t2' s)
mapTableM f (Overlay t1 t2 s) = do
    t1' <- mapTableM f t1
    t2' <- mapTableM f t2
    return (Overlay t1' t2' s)
mapTableM _ Empty = return Empty
mapTableM _ Null = return Null

----------------------------------------------------------------------
type FlatTable a = Array (Int,Int) [(a,Span,SpaceWeight)]

flatten :: Table a -> FlatTable a
flatten t = accumArray (flip (:)) [] ((0,0), (width t - 1, height t - 1))
                       (flatten2 (0,0) t [])

type FlatEl a = ((Int,Int),Cell a)

flatten2 :: (Int,Int) -> Table a -> [FlatEl a] -> [FlatEl a]
flatten2 i Empty els = els
flatten2 i Null els = els
flatten2 i (Value cell) els = (i,cell):els

flatten2 i@(x,y) (Above t1 t2 size) els = (f1.f2) els
  where
    f1 = flatten2 i t1
    f2 = flatten2 (x,y + height t1) t2

flatten2 i@(x,y) (Beside t1 t2 size) els = (f1.f2) els
  where
    f1 = flatten2 i t1
    f2 = flatten2 (x + width t1, y) t2

flatten2 i@(x,y) (Overlay t1 t2 size) els = (f1.f2) els
  where
    f1 = flatten2 i t1
    f2 = flatten2 i t2

foldT :: ((Int,Int) -> Cell a -> r -> r) -> r -> FlatTable a -> r
foldT f iv ft = foldr f' iv (assocs ft)
  where
    f' (i,vs) r = foldr (\cell -> f i cell) r vs  

----------------------------------------------------------------------
type DArray = Array Int Double

renderTable :: Table (Renderable a) -> Renderable ()
renderTable t = Renderable minsizef renderf
  where
    getSizes :: CRender (DArray, DArray, DArray, DArray)
    getSizes = do
        szs <- mapTableM minsize t :: CRender (Table RectSize)
        let szs' = flatten szs
        let widths = accumArray max 0 (0, width t - 1) (foldT (ef wf) [] szs')
        let heights  = accumArray max 0 (0, height t - 1) (foldT (ef hf) [] szs')
        let xweights = accumArray max 0 (0, width t - 1) (foldT (ef xwf) [] szs')
        let yweights = accumArray max 0 (0, height t - 1) (foldT (ef ywf) [] szs')
        return (widths,heights,xweights,yweights)

    wf  (x,y) (w,h) (ww,wh) = (x,w)
    hf  (x,y) (w,h) (ww,wh) = (y,h)
    xwf (x,y) (w,h) (xw,yw) = (x,xw)
    ywf (x,y) (w,h) (xw,yw) = (y,yw)

    ef f loc (size,span,ew) | span == (1,1) = (f loc size ew:)
                            | otherwise = id
                                        
    minsizef = do
        (widths, heights, xweights, yweights) <- getSizes
        return (sum (elems widths), sum (elems heights))

    renderf (w,h)  = do
        (widths, heights, xweights, yweights) <- getSizes
        let widths' = addExtraSpace w widths xweights
        let heights' = addExtraSpace h heights yweights
        let csizes = (ctotal widths',ctotal heights')
        forM_ (assocs (flatten t)) $ \(loc,rs) -> do
            forM_ rs $ \(r,sz,ew) -> do
            let rr@(Rect (Point x0 y0) (Point x1 y1)) = mkRect csizes loc sz
            preserveCState $ do
                c $ C.translate x0 y0
                render r (x1-x0,y1-y0)
        return (const ())
      where
        mkRect :: (DArray, DArray) -> (Int,Int) -> (Int,Int) -> Rect
        mkRect (cwidths,cheights) (x,y) (w,h) = Rect (Point x1 y1) (Point x2 y2)
          where
            x1 = cwidths ! x
            y1 = cheights ! y
            x2 = cwidths ! min (x+w) (snd $ bounds cwidths) 
            y2 = cheights ! min (y+h) (snd $ bounds cheights)
            mx = fst (bounds cwidths)
            my = fst (bounds cheights)

        addExtraSpace :: Double -> DArray -> DArray -> DArray
        addExtraSpace size sizes weights = 
            if totalws == 0 then sizes
                            else listArray (bounds sizes) sizes'
          where
            ws = elems weights
            totalws = sum ws
            extra = size - sum (elems sizes)
            extras =  map (*(extra/totalws)) ws
            sizes' = zipWith (+) extras (elems sizes)

    ctotal :: DArray -> DArray
    ctotal a = listArray (let (i,j) = bounds a in (i,j+1)) (scanl (+) 0 (elems a))
