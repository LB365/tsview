module Rename exposing (main)

import Browser
import Common exposing (classes)
import Dict exposing (Dict)
import Html.Styled exposing (..)
import Html.Styled.Attributes exposing (value)
import Html.Styled.Events exposing (onInput, onMouseDown)
import Http
import Catalog exposing (RawSeriesCatalog, SeriesCatalog, buildCatalog, getCatalog)
import Json.Decode as Decode
import KeywordSelector
import KeywordSingleSelector
import SeriesSelector
import Tachyons.Classes as T
import Time
import Url.Builder as UB


type State
    = Select
    | Edit


type alias Model =
    { urlPrefix : String
    , state : State
    , catalog : SeriesCatalog
    , search : SeriesSelector.Model
    , renamedSerie : String
    , error : Maybe String
    }


type Msg
    = CatalogReceived (Result String RawSeriesCatalog)
    | ToggleItem String
    | SearchSeries String
    | MakeSearch
    | SelectMode
    | EditMode
    | NewSerieName String
    | OnRename
    | RenameDone (Result String String)


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    let
        removeItem x xs =
            List.filter ((/=) x) xs

        toggleitem elt list =
            if
                List.member elt list
            then
                []
            else
                List.singleton elt

        newModel x = ( x, Cmd.none )

        keywordMatch xm xs =
            if String.length xm < 2 then
                []
            else
                KeywordSelector.select xm xs |> List.take 20
    in
        case msg of
            CatalogReceived (Ok x) ->
                ( { model | catalog = buildCatalog x }
                , Cmd.none
                )

            CatalogReceived (Err x) ->
                newModel { model | error = Just x }

            ToggleItem x ->
                newModel { model | search = SeriesSelector.updateselected
                                            model.search
                                            (toggleitem x model.search.selected)
                         }

            SearchSeries x ->
                newModel { model | search = SeriesSelector.updatesearch
                                            model.search
                                            x
                         }

            MakeSearch ->
                let
                    newsearch = SeriesSelector.updatefound
                                model.search
                                    (keywordMatch
                                         model.search.search
                                         model.catalog.series)
                in
                    newModel { model | search = newsearch }

            EditMode ->
                newModel
                { model
                    | state = Edit
                    , renamedSerie = Maybe.withDefault "" (List.head model.search.selected)
                }

            SelectMode ->
                newModel { model | state = Select, error = Nothing }

            NewSerieName x ->
                newModel { model | renamedSerie = x, error = Nothing }

            OnRename ->
                let
                    expect =
                        Common.expectJsonMessage RenameDone Decode.string

                    url =
                        UB.crossOrigin model.urlPrefix
                            [ "api", "series", "state" ]
                            [ UB.string "name" <|
                                  Maybe.withDefault "" (List.head model.search.selected)
                            , UB.string "newname" model.renamedSerie
                            ]

                    putRequest =
                        Http.request
                            { method = "PUT"
                            , headers = []
                            , url = url
                            , body = Http.emptyBody
                            , expect = expect
                            , timeout = Nothing
                            , tracker = Nothing
                            }
                in
                    ( model, putRequest )

            RenameDone (Ok _) ->
                ( { model
                      | state = Select
                      , search = SeriesSelector.null
                      , renamedSerie = ""
                      , error = Nothing
                  }
                , getCatalog model.urlPrefix (Common.expectJsonMessage CatalogReceived)
                )

            RenameDone (Err x) ->
                newModel { model | error = Just x }


selectorConfig : KeywordSingleSelector.Config Msg
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
                { attrs = [ classes [ T.white, T.bg_blue ] ]
                , html = text "Rename"
                , clickMsg = EditMode
                }
          , defaultText = text ""
          , toggleMsg = ToggleItem
          }
    , onInputMsg = SearchSeries
    , divAttrs = [ classes [ T.aspect_ratio, T.aspect_ratio__1x1, T.mb4 ] ]
    }


editor : Model -> Html Msg
editor model =
    let
        edit =
            let
                txt =
                    "New name for : " ++ Maybe.withDefault "" (List.head model.search.selected)

                lab =
                    label
                    [ classes [ T.db, T.fw1, T.lh_copy ] ]
                    [ text txt ]

                inputClass =
                    classes
                    [ T.input_reset
                    , T.dtc
                    , T.ba
                    , T.b__black_20
                    , T.pa2
                    , T.db
                    , T.w_100
                    ]

                inpt =
                    input
                    [ inputClass
                    , value model.renamedSerie
                    , onInput NewSerieName
                    ] []
            in
                div [ classes [ T.mb3 ] ] [ lab, inpt ]

        button ( txt, bg_color, toMsg ) =
            let
                aClass =
                    classes
                    [ T.link
                    , T.dim
                    , T.ph3
                    , T.pv2
                    , T.ma2
                    , T.dib
                    , T.tc
                    , T.white
                    , bg_color
                    ]
            in
                a [ aClass, onMouseDown toMsg ] [ text txt ]

        buttonAttrs =
            [ ( "Rename", T.bg_blue, OnRename )
            , ( "Cancel", T.bg_light_red, SelectMode )
            ]

        buttons =
            div [] (List.map button buttonAttrs)

        addErr mess =
            let
                cls =
                    classes
                    [ T.flex
                    , T.items_center
                    , T.justify_center
                    , T.pa4
                    , T.bg_washed_red
                    , T.navy
                    ]
            in
                [ div [ cls ] [ text mess ] ]

        checkErr xs =
            Common.maybe xs (addErr >> List.append xs) model.error
    in
        div selectorConfig.divAttrs <| checkErr [ edit, buttons ]


view : Model -> Html Msg
view model =
    let
        ctx =
            KeywordSingleSelector.Context
                model.search.search
                model.search.found
                (List.head model.search.selected)
                (Maybe.map text model.error)

        content =
            case model.state of
                Select ->
                    KeywordSingleSelector.view selectorConfig ctx

                Edit ->
                    editor model
    in
        article [ classes [ T.center, T.pt4, T.w_90 ] ] [ content ]


main : Program String Model Msg
main =
    let
        init urlPrefix =
            let
                prefix = Common.checkUrlPrefix urlPrefix
            in
                (
                 Model
                     prefix
                     Select
                     (buildCatalog (Dict.empty))
                     SeriesSelector.null
                     ""
                     Nothing
                ,
                    getCatalog prefix (Common.expectJsonMessage CatalogReceived)
                )

        sub model =
            if
                model.state == Select
            then
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
