import Testing
@testable import PodcastCore

@Test func markdownSplitsHeadingsBulletsAndNumberedSteps() {
    let blocks = Markdown.blocks("""
    ## 含义
    这句话表示**坚持**很重要。
    - 主句：*keep going*
    - 从句：`as long as`
    1. 先看主语
    2) 再看时态
    ---
    """)
    #expect(blocks == [
        .heading(level: 2, text: "含义"),
        .paragraph("这句话表示**坚持**很重要。"),
        .bullet("主句：*keep going*"),
        .bullet("从句：`as long as`"),
        .numbered(marker: "1.", text: "先看主语"),
        .numbered(marker: "2.", text: "再看时态"),
    ])
}

@Test func markdownKeepsWrappedParagraphsTogetherAndSkipsCodeFences() {
    let blocks = Markdown.blocks("""
    第一行
    第二行

    ```
    let x = 1
    ```
    > 引用的一句话
    #
    - 
    2024. 不是列表
    """)
    #expect(blocks == [.paragraph("第一行\n第二行"), .paragraph("引用的一句话"), .paragraph("2024. 不是列表")])
}

@Test func markdownFallsBackToAParagraphForPlainText() {
    #expect(Markdown.blocks("用简体中文解释一下。") == [.paragraph("用简体中文解释一下。")])
    #expect(Markdown.blocks("   \n\n ").isEmpty)
}
