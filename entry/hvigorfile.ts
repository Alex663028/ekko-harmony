import { hapTasks } from '@ohos/hvigor-ohos-plugin';

export default {
  // 内置 Hvigor 插件，不可修改。
  // 模块级必须是 hapTasks（不是 appTasks）：
  // 用 appTasks 会让 hvigor 把模块配置按 project schema 校验，
  // 从而报"The project-level build-profile.json5 file does not comply with the schema"。
  system: hapTasks,
  plugins: []
}