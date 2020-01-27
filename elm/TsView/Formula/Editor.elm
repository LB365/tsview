module TsView.Formula.Editor exposing (main)

import Browser
import Common
import Dict
import Either exposing (Either(..))
import Html as H exposing (Attribute, Html)
import Html.Attributes as A
import Html.Parser
import Html.Parser.Util exposing (toVirtualDom)
import Http
import Json.Decode as Decode
import Lazy.LList as LL
import Lazy.Tree as Tree exposing (Tree(..))
import Lazy.Tree.Zipper as Zipper exposing (Zipper)
import List.Nonempty as NE exposing (Nonempty)
import Tachyons exposing (classes)
import Tachyons.Classes as T
import Time
import TsView.Formula.Renderer exposing (renderString)
import TsView.Formula.Spec as S exposing (Model, Msg(..))
import TsView.Formula.ViewEditor exposing (viewEditor)
import Url.Builder as UB


updateEditor : Zipper S.EditionNode -> String -> Model -> Zipper S.EditionNode
updateEditor zipper s model =
    let
        n =
            Zipper.current zipper
    in
    case n.specType of
        S.Operator _ _ _ ->
            let
                ops =
                    S.listOperators model.spec |> Dict.fromList

                specZipper =
                    Zipper.update
                        (\_ ->
                            Dict.get s ops
                                |> Maybe.withDefault (NE.head model.spec)
                                |> S.buildSpecTree model.spec
                        )
                        (Zipper.map .specType zipper)
            in
            Zipper.update (\_ -> S.buildEditionNode specZipper) zipper

        S.Union _ ->
            Zipper.open (always True) zipper
                |> Maybe.map
                    (Zipper.update (\_ -> S.fromString s |> model.buildEditionTree))
                |> Maybe.withDefault zipper

        _ ->
            Zipper.updateItem
                (\x -> { x | input = S.readInput x.input x.specType s })
                zipper


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    let
        formula =
            model.formula

        newTreeModel zipper =
            let
                root =
                    Zipper.root zipper
            in
            ( { model
                | tree = Zipper.getTree root
                , formula = { formula | current = renderString root }
              }
            , Cmd.none
            )
    in
    case msg of
        ToggleNode zipper ->
            newTreeModel <|
                Zipper.updateItem
                    (\n ->
                        let
                            flags =
                                n.editFlags
                        in
                        { n | editFlags = { flags | isOpen = not flags.isOpen } }
                    )
                    zipper

        EditList zipper S.ListAdd ->
            S.getSpecType zipper
                |> model.buildEditionTree
                |> Tree.descendants
                |> LL.foldl (\a b -> Zipper.insert a b) zipper
                |> newTreeModel

        EditList zipper S.ListRemove ->
            Zipper.attempt Zipper.delete zipper
                |> newTreeModel

        EditNode zipper s ->
            newTreeModel <| updateEditor zipper s model

        Render ->
            if formula.rendered /= formula.current then
                ( { model | formula = { formula | rendered = formula.current } }
                , Http.post
                    { url =
                        UB.crossOrigin
                            model.urlPrefix
                            [ "tsformula", "pygmentize" ]
                            []
                    , body = Http.stringBody "text/plain" formula.current
                    , expect = Common.expectJsonMessage CodeHighlight Decode.string
                    }
                )

            else
                ( model, Cmd.none )

        CodeHighlight (Ok x) ->
            let
                code =
                    Html.Parser.run x
                        |> Either.fromResult
                        |> Either.mapBoth
                            (\_ -> "Could not parse : " ++ x)
                            toVirtualDom
            in
            ( { model | formula = { formula | code = code } }, Cmd.none )

        CodeHighlight (Err x) ->
            ( { model | formula = { formula | code = Left x } }, Cmd.none )


view : Model -> Html Msg
view model =
    let
        formula =
            model.formula

        errMess =
            let
                itemize =
                    H.text >> List.singleton >> H.li []
            in
            Maybe.map
                (\xs -> H.ul [ A.style "margin" "30px" ] (List.map itemize xs))
                model.specParsingError
                |> Maybe.withDefault
                    (H.text "")
    in
    H.article []
        [ errMess
        , H.div [ classes [ T.fl, T.w_90, T.ma3 ] ]
            (Either.unpack (H.text >> List.singleton) identity formula.code)
        , viewEditor model
        ]


main : Program ( String, S.JsonSpec ) Model Msg
main =
    let
        init ( urlPrefix, jsonSpec ) =
            let
                ( specError, spec ) =
                    S.parseJsonSpec jsonSpec

                buildEditionTree =
                    S.buildEditionTree spec

                defaultOperator =
                    NE.head spec

                tree =
                    buildEditionTree defaultOperator
            in
            ( Model
                urlPrefix
                spec
                specError
                buildEditionTree
                tree
                (S.Formula
                    (renderString <| Zipper.fromTree tree)
                    ""
                    (Left "No rendering")
                )
            , Cmd.none
            )

        sub model =
            Time.every 1000 (always Render)
    in
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = sub
        }
