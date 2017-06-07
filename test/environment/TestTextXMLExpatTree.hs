{-
TorXakis - Model Based Testing
Copyright (c) 2015-2016 TNO and Radboud University
See license.txt
-}

module TestTextXMLExpatTree
(
testTextXMLExpatTreeList
)
where
import Test.HUnit
import Text.XML.Expat.Tree
import Data.ByteString.Lazy (pack)
import Data.ByteString.Internal (c2w)
import Data.Maybe (isJust)

testEmpty :: Test
testEmpty = TestCase $ do
    let (xml, mErr) = ( parse defaultParseOptions (pack $ map c2w "") ) :: (UNode String, Maybe XMLParseError)  in do
        assertBool "empty string fails" (isJust mErr)

testSingleNode :: Test
testSingleNode = TestCase $ 
    let nodeName = "singleNode" in
        let (xml, mErr) = ( parse defaultParseOptions (pack $ map c2w ("<" ++ nodeName ++ "></" ++ nodeName ++ ">") ) ) :: (UNode String, Maybe XMLParseError)  in do
            assertEqual ("Single Node - err : " ++ show mErr) (Element nodeName [] []) xml

testSingleTextNode :: Test
testSingleTextNode = TestCase $ 
    let nodeName = "singleNode" in
        let nodeText = "text text text" in
        let (xml, mErr) = ( parse defaultParseOptions (pack $ map c2w ("<" ++ nodeName ++ ">" ++ nodeText ++ "</" ++ nodeName ++ ">") ) ) :: (UNode String, Maybe XMLParseError)  in do
            assertEqual ("Single Text Node - err : " ++ show mErr) (Element nodeName [] [Text nodeText]) xml

-- reference to invalid character number  (https://en.wikipedia.org/wiki/Valid_characters_in_XML)
-- according to XML 1.0
-- yet valid for XML 1.1    -- http://www.w3.org/TR/xml11/#charsets
testInvalidCharacterNumber :: Test
testInvalidCharacterNumber = TestCase $
    let nodeName = "singleNode" in
        let nodeText = "&#1;" in
            let (xml, mErr) = ( parse defaultParseOptions (pack $ map c2w ("<" ++ nodeName ++ ">" ++ nodeText ++ "</" ++ nodeName ++ ">") ) ) :: (UNode String, Maybe XMLParseError)  in do
                -- putStrLn (show mErr)
                assertBool "invalid character number" (isJust mErr)
        
testSingleEscapedTextNode :: Test
testSingleEscapedTextNode = TestCase $ 
    let nodeName = "singleNode" in
        let nodeText    = "a text with escaped characters &amp; &lt; &gt; &#x21; &#34; is correctly handled!"
            expectedText= "a text with escaped characters & < > ! \" is correctly handled!" in
                let (xml, mErr) = ( parse defaultParseOptions (pack $ map c2w ("<" ++ nodeName ++ ">" ++ nodeText ++ "</" ++ nodeName ++ ">") ) ) :: (UNode String, Maybe XMLParseError)  in do
                    assertEqual ("Single Escaped Text Node - err : " ++ show mErr) (Element nodeName [] [Text expectedText]) (concatTexts xml) 
    where 
        concatTexts (Element n [] l) = Element n [] (concatText l)
        
        concatText (Text a: Text b : [] )   = [Text (a++b)]
        concatText (Text a: Text b : xs )   = concatText (Text (a++b):xs)
        concatText (a:xs)                   = (a:concatText xs)

testNestedNode :: Test
testNestedNode = TestCase $ 
    let rootNodeName = "rootNode" in
        let nestedNodeName = "nestedNode" in
            let (xml, mErr) = ( parse defaultParseOptions (pack $ map c2w ("<" ++ rootNodeName ++ ">" ++ "<" ++ nestedNodeName ++ "></" ++ nestedNodeName ++ ">" ++ "</" ++ rootNodeName ++ ">") ) ) :: (UNode String, Maybe XMLParseError)  in do
                assertEqual ("Single Nested Node - err : " ++ show mErr) (Element rootNodeName [] [Element nestedNodeName [] []]) xml 

-- text and elements can be mixed 
-- see e.g. https://blogs.msdn.microsoft.com/xmlteam/2004/12/30/elements-containing-either-text-or-other-elements/
testMixedContent :: Test
testMixedContent = TestCase $ 
    let rootNodeName = "rootNode" in
        let nestedNodeName = "nestedNode" in
            let (xml, mErr) = ( parse defaultParseOptions (pack $ map c2w ("<" ++ rootNodeName ++ ">text1" ++ 
                                                                                "<" ++ nestedNodeName ++ ">text2</" ++ nestedNodeName ++ ">text3" ++ 
                                                                                "<" ++ nestedNodeName ++ ">text4</" ++ nestedNodeName ++ ">text5" ++ 
                                                                           "</" ++ rootNodeName ++ ">") ) ) :: (UNode String, Maybe XMLParseError)  in do
                assertEqual ("Single Nested Node - err : " ++ show mErr) (Element rootNodeName []   [   Text "text1"
                                                                                                    ,   Element nestedNodeName [] [Text "text2"]
                                                                                                    ,   Text "text3"
                                                                                                    ,   Element nestedNodeName [] [Text "text4"]
                                                                                                    ,   Text "text5"
                                                                                                    ]) 
                                                                                                    xml 

----------------------------------------------------------------------------------------
-- List of Tests
----------------------------------------------------------------------------------------
testTextXMLExpatTreeList = TestList [
      TestLabel "empty"                             testEmpty
    , TestLabel "Single Node"                       testSingleNode
    , TestLabel "Single Text Node"                  testSingleTextNode
    , TestLabel "Invalid Character Number XML 1.0"  testInvalidCharacterNumber
    , TestLabel "Single Escaped Text Node"          testSingleEscapedTextNode
    , TestLabel "Nested Node"                       testNestedNode
    , TestLabel "Mixed Content"                     testMixedContent
    ]