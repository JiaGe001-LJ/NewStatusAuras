NewStatusAuras 字体目录

将 .ttf 或 .otf 字体文件放入此目录后，在 Config\DeveloperDefaults.lua 的 fonts 列表中登记：
{ key = "myfont", name = "我的字体", path = "Interface\\AddOns\\NewStatusAuras\\Fonts\\MyFont.ttf" }

魔兽世界插件不能自动枚举文件夹内容，因此新增字体需要在配置文件中登记后才能出现在编辑器选择菜单。
