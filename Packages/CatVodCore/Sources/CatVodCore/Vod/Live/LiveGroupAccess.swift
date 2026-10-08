import Foundation

/// 加密（隐藏）分组的可见性与解锁（上游 `LiveActivity` 的 `mHides` + `unlock(pass)`）。
///
/// 上游的语义（`Group.isHidden()` = 密码非空）：
/// - 隐藏分组**不进**正常分组列表，而是收在 `mHides` 里 —— 也就是说，没解锁就**看不到**这些组；
/// - 用户输密码（`setPass` → `unlock(pass)`）把 `pass.equals(item.getPass())` 的组搬进正常列表，
///   并且**第一组解锁后立刻选中**；
/// - 生物识别成功时传 `null` → 解锁全部隐藏组（本项目不做生物识别，这条不实现）。
///
/// 本项目此前只给这类分组画了个锁标、却照常把频道列出来 —— 等于「看起来做了、其实没拦」。
/// 这个类型把上面两条落成纯逻辑，界面只管调用。
public enum LiveGroupAccess {
    /// 界面要显示的分组：**未解锁的隐藏组不出现**（上游把它们收在 `mHides` 里）。
    public static func visible(_ groups: [LiveGroup], unlocked: Set<String>) -> [LiveGroup] {
        groups.filter { !$0.isHidden || unlocked.contains(key($0)) }
    }

    /// 还锁着的隐藏组（界面据此决定要不要给「解锁」入口、以及入口上写几个）。
    public static func locked(_ groups: [LiveGroup], unlocked: Set<String>) -> [LiveGroup] {
        groups.filter { $0.isHidden && !unlocked.contains(key($0)) }
    }

    /// 用密码解锁：返回这次能解锁的组（上游 `pass.equals(item.getPass())`，**严格相等、区分大小写**）。
    ///
    /// 空密码不解锁任何组 —— 上游 `unlock(null)` 那条是「生物识别成功 = 解锁全部」，本项目不做生物识别。
    public static func unlocking(_ groups: [LiveGroup], with pass: String) -> [LiveGroup] {
        guard !pass.isEmpty else {
            return []
        }
        return groups.filter { $0.isHidden && $0.pass == pass }
    }

    /// 解锁状态的键：用 ``LiveGroup/id``（名字 + 密码），换源后不会撞。
    public static func key(_ group: LiveGroup) -> String {
        group.id
    }
}
