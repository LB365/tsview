port module Plot exposing (main)

import Browser
import Common exposing (classes)
import Dict
import Either exposing (Either)
import Html.Styled exposing (..)
import Html.Styled.Events exposing (onClick)
import Http
import Json.Decode as Decode exposing (Decoder)
import KeywordMultiSelector
import KeywordSelector
import LruCache exposing (LruCache)
import Tachyons.Classes as T
import Task exposing (Task)
import Time
import Url
import Url.Builder as UB


type alias Model =
    { urlPrefix : String
    , series : List String
    , searchString : String
    , searchedSeries : List String
    , selectedSeries : List String
    , activeSelection : Bool
    , cache : SeriesCache
    }


type alias SeriesCatalog =
    Dict.Dict String String


type alias Serie =
    Dict.Dict String Float


type alias NamedSerie =
    ( String, Serie )


serieDecoder : Decoder Serie
serieDecoder =
    Decode.dict Decode.float


type alias SeriesCache =
    LruCache String Serie


type Msg
    = CatalogReceived (Result Http.Error SeriesCatalog)
    | ToggleSelection
    | ToggleItem String
    | SearchSeries String
    | MakeSearch
    | OnApply
    | GotPlot (Result Http.Error String)
    | RenderPlot (Result String ( SeriesCache, List NamedSerie ))


type alias Trace =
    { type_ : String
    , name : String
    , x : List String
    , y : List Float
    , mode : String
    }


type alias TraceArgs =
    String -> List String -> List Float -> String -> Trace


scatterPlot : TraceArgs
scatterPlot =
    Trace "scatter"


type alias PlotArgs =
    { data : List Trace
    }


port renderPlot : PlotArgs -> Cmd msg


type alias RenderArgs =
    { plotlyResponse : String
    , selectedSeries : List String
    , permalinkQuery : String
    }


port renderPlotly : RenderArgs -> Cmd msg


fetchSeries : List String -> Model -> Task String ( SeriesCache, List NamedSerie )
fetchSeries selectedNames model =
    let
        ( usedCache, cachedSeries ) =
            List.foldr
                (\name ( cache, xs ) ->
                    let
                        ( newCache, maybeSerie ) =
                            LruCache.get name cache

                        x : Either String NamedSerie
                        x =
                            maybeSerie
                                |> Either.fromMaybe name
                                |> Either.map (Tuple.pair name)
                    in
                    ( newCache, x :: xs )
                )
                ( model.cache, [] )
                selectedNames

        missingNames =
            Either.lefts cachedSeries

        getSerie : String -> Task String Serie
        getSerie serieName =
            Http.task
                { method = "GET"
                , url =
                    UB.crossOrigin
                        model.urlPrefix
                        [ "api", "series", "state" ]
                        [ UB.string "name" serieName ]
                , headers = []
                , body = Http.emptyBody
                , timeout = Nothing
                , resolver =
                    Http.stringResolver <|
                        Common.decodeJsonMessage serieDecoder
                }

        getMissingSeries : Task String (List Serie)
        getMissingSeries =
            Task.sequence <| List.map getSerie missingNames

        getSeries : List NamedSerie -> List NamedSerie
        getSeries missing =
            let
                series =
                    List.append (Either.rights cachedSeries) missing
                        |> Dict.fromList
            in
            List.foldr
                (\a b -> Common.maybe b (\x -> ( a, x ) :: b) (Dict.get a series))
                []
                selectedNames

        updateCache : List NamedSerie -> SeriesCache
        updateCache missing =
            List.foldl
                (\( name, serie ) cache -> LruCache.insert name serie cache)
                usedCache
                missing
    in
    getMissingSeries
        |> Task.andThen
            (\missingSeries ->
                let
                    xs =
                        List.map2 Tuple.pair missingNames missingSeries
                in
                Task.succeed ( updateCache xs, getSeries xs )
            )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    let
        removeItem x xs =
            List.filter ((/=) x) xs

        toggleItem x xs =
            if List.member x xs then
                removeItem x xs

            else
                x :: xs

        newModel x =
            ( x, Cmd.none )

        keywordMatch xm xs =
            if String.length xm < 2 then
                []

            else
                KeywordSelector.select xm xs |> List.take 20

        plotUrl =
            UB.crossOrigin model.urlPrefix
                [ "tsplot" ]
                (List.map (\x -> UB.string "series" x) model.selectedSeries)
    in
    case msg of
        CatalogReceived (Ok x) ->
            let
                series =
                    Dict.keys x
            in
            newModel { model | series = series }

        CatalogReceived (Err x) ->
            let
                _ =
                    Debug.log "Error on CatalogReceived" x
            in
            newModel model

        ToggleSelection ->
            newModel { model | activeSelection = not model.activeSelection }

        ToggleItem x ->
            let
                selectedSeries =
                    toggleItem x model.selectedSeries
            in
            ( { model | selectedSeries = selectedSeries }
            , Task.attempt RenderPlot <| fetchSeries selectedSeries model
            )

        SearchSeries x ->
            newModel { model | searchString = x }

        MakeSearch ->
            newModel { model | searchedSeries = keywordMatch model.searchString model.series }

        RenderPlot (Ok ( cache, namedSeries )) ->
            let
                vals =
                    List.map
                        (\( name, serie ) ->
                            scatterPlot
                                name
                                (Dict.keys serie)
                                (Dict.values serie)
                                "lines"
                        )
                        namedSeries
            in
            ( { model | cache = cache }, renderPlot <| PlotArgs vals )

        RenderPlot (Err x) ->
            let
                _ =
                    Debug.log "Error on RenderPlot" x
            in
            newModel model

        OnApply ->
            ( model, Http.get { url = plotUrl, expect = Http.expectString GotPlot } )

        GotPlot (Ok x) ->
            let
                validUrl =
                    Common.maybe
                        ("http://dummy" ++ plotUrl)
                        (always plotUrl)
                        (Url.fromString plotUrl)

                q =
                    validUrl
                        |> Url.fromString
                        |> Maybe.map (.query >> Maybe.withDefault "")
                        |> Maybe.withDefault ""
            in
            ( model, renderPlotly <| RenderArgs x model.selectedSeries q )

        GotPlot (Err x) ->
            let
                _ =
                    Debug.log "Error on GotPlot" x
            in
            newModel model


selectorConfig : KeywordMultiSelector.Config Msg
selectorConfig =
    { searchSelector =
        { action = Nothing
        , defaultText =
            text
                "Type some keywords in input bar for selecting time series"
        , toggleMsg = ToggleItem
        }
    , actionSelector =
        { action =
            Just
                { attrs = [ classes [ T.white, T.bg_dark_blue ] ]
                , html = text "Apply"
                , clickMsg = OnApply
                }
        , defaultText = text ""
        , toggleMsg = ToggleItem
        }
    , onInputMsg = SearchSeries
    , divAttrs = [ classes [ T.mb4 ] ]
    }


view : Model -> Html Msg
view model =
    let
        cls =
            classes [ T.pb2, T.f4, T.fw6, T.db, T.navy, T.link, T.dim ]

        children =
            [ a [ cls, onClick ToggleSelection ] [ text "Series selection" ] ]

        ctx =
            KeywordMultiSelector.Context
                model.searchString
                model.searchedSeries
                model.selectedSeries
    in
    div [ classes [ T.center, T.pt4, T.w_90 ] ]
        (if model.activeSelection then
            List.append children
                [ KeywordMultiSelector.view selectorConfig ctx
                ]

         else
            children
        )


main : Program String Model Msg
main =
    let
        initialGet urlPrefix =
            Http.get
                { expect = Http.expectJson CatalogReceived (Decode.dict Decode.string)
                , url =
                    UB.crossOrigin urlPrefix
                        [ "api", "series", "catalog" ]
                        []
                }

        init urlPrefix =
            let
                p =
                    Common.checkUrlPrefix urlPrefix

                c =
                    LruCache.empty 100
            in
            ( Model p [] "" [] [] True c, initialGet p )

        sub model =
            if model.activeSelection then
                Time.every 1000 (always MakeSearch)

            else
                Sub.none
    in
    Browser.element
        { init = init
        , view = view >> toUnstyled
        , update = update
        , subscriptions = sub
        }
