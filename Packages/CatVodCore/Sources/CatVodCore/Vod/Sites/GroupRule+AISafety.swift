public extension GroupRule {
    /// AI 生成的规则只允许「线性、可预测」的正则子集（逐条对齐上游 `GroupRule.isSafeAiRegex`）。
    ///
    /// 为什么卡这么死：AI 写的正则没人 review 过，而 `^(a|aa)+$`、`^(\w+\s?)*$` 这类在长文本上会指数回溯 ——
    /// 卡在匹配入口比事后加超时省事得多。允许的形态大致是：字面量 / 字符类 / `\s\S\d\D\w\W` / 非捕获组
    /// `(?:…)` / 少量量词，且**必须正好一个捕获组**（抽标签要它）、没有 `.`、`|`、`{n,m}`、回溯引用。
    static func isSafeAIRegExp(_ regex: String) -> Bool {
        var scanner = AIGroupRuleSafety(regex: regex)
        return scanner.isSafe()
    }
}

/// AI 规则的正则安全子集扫描器（逐字符状态机，逐条对齐上游 `GroupRule.isSafeAiRegex`）。
///
/// 为什么单独立一个类型、而不是全塞进一个方法：这套判定天生一堆分支，堆在一个方法里会同时撞上
/// SwiftLint 的 `function_body_length` 与 `cyclomatic_complexity`（仓库把这两条设成了阻断项）。
/// 拆开之后每个方法都短、都能单独读，语义仍与上游一一对应。
struct AIGroupRuleSafety {
    /// 与上游一致的正则长度上限。
    private static let maxLength = 256

    private let characters: [Character]
    private var index = 0
    private var depth = 0
    private var captures = 0
    private var quantifiersByDepth: [Int]
    private var inClass = false
    private var escaped = false
    private var classHasContent = false
    private var atom = false
    private var groupAtom = false
    private var quantified = false

    init(regex: String) {
        characters = Array(regex)
        quantifiersByDepth = [Int](repeating: 0, count: GroupRule.maxAINestingDepth + 1)
        // `(?i)` 是唯一的全局前缀，跳过它（否则会被当成 `(` 走进组处理）。
        index = regex.hasPrefix("(?i)") ? 4 : 0
    }

    /// 整条正则是否落在安全子集里（扫一遍；`escaped` / `inClass` / 深度 / 捕获组数都要收干净）。
    mutating func isSafe() -> Bool {
        guard !characters.isEmpty, characters.count <= Self.maxLength else { return false }
        guard !characters.contains("\n"), !characters.contains("\r") else { return false }
        while index < characters.count {
            let character = characters[index]
            if escaped {
                guard acceptEscaped(character) else { return false }
                index += 1
                continue
            }
            guard accept(character) else { return false }
            index += 1
        }
        // 收尾：转义没收尾、字符类没闭合、组没配平、捕获组不是「正好一个」—— 都不安全。
        return !escaped && !inClass && depth == 0 && captures == 1
    }

    /// 转义后的那个字符：只认 `\s\S\d\D\w\W`（数字引用 `\1`、字母转义 `\b` 一律不放行）。
    private mutating func acceptEscaped(_ character: Character) -> Bool {
        if character.isNumber { return false }
        if character.isLetter, !"sSdDwW".contains(character) { return false }
        escaped = false
        if inClass {
            classHasContent = true
        } else {
            markAtom()
        }
        return true
    }

    /// 普通字符分发；字符类里的字符只做「闭合 / 记内容」两件事。
    private mutating func accept(_ character: Character) -> Bool {
        if inClass {
            acceptInClass(character)
            return true
        }
        switch character {
        case "\\":
            escaped = true
        case "[":
            openClass()
        case ".", "|", "{", "}":
            return false
        case "(":
            return openGroup()
        case ")":
            return closeGroup()
        case "*", "+", "?":
            return acceptQuantifier(character)
        case "^", "$":
            markStart()
        default:
            markAtom()
        }
        return true
    }

    /// 字符类里：`]` 且类里已经有内容才算闭合（`[]]` 的第一个 `]` 算内容）。
    private mutating func acceptInClass(_ character: Character) {
        if character == "]", classHasContent {
            inClass = false
            markAtom()
        } else {
            classHasContent = true
        }
    }

    private mutating func openClass() {
        inClass = true
        classHasContent = false
        markStart()
    }

    /// 组：`(?` 只认非捕获组 `(?:`，其余 `(?…)` 一律拒；捕获组计数 +1；深度超上限直接判不安全。
    private mutating func openGroup() -> Bool {
        if index + 1 < characters.count, characters[index + 1] == "?" {
            guard index + 2 < characters.count, characters[index + 2] == ":" else { return false }
            index += 2
        } else {
            captures += 1
        }
        depth += 1
        guard depth <= GroupRule.maxAINestingDepth else { return false }
        markStart()
        return true
    }

    private mutating func closeGroup() -> Bool {
        guard depth > 0 else { return false }
        depth -= 1
        atom = true
        groupAtom = true
        quantified = false
        return true
    }

    /// 量词：`?` 跟在量词后面是「惰性」标记（不改计数）；否则前面要有原子、同层量词不能超上限。
    private mutating func acceptQuantifier(_ character: Character) -> Bool {
        if character == "?", quantified {
            quantified = false
            return true
        }
        guard atom, !groupAtom, !quantified else { return false }
        quantifiersByDepth[depth] += 1
        guard quantifiersByDepth[depth] <= GroupRule.maxAIQuantifiersPerDepth else { return false }
        quantified = true
        return true
    }

    /// 已经形成一个可被量词的原子。
    private mutating func markAtom() {
        atom = true
        groupAtom = false
        quantified = false
    }

    /// 组结构 / 边界之后：还没形成原子（`(` `[` `^` `$`）。
    private mutating func markStart() {
        atom = false
        groupAtom = false
        quantified = false
    }
}
