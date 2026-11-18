package smart

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"
)

// nvmeLogOrder 固定展示顺序，保证每次输出的字段次序一致。
var nvmeLogOrder = []string{
	"nsid", "critical_warning", "temperature", "available_spare",
	"available_spare_threshold", "percentage_used", "data_units_read",
	"data_units_written", "host_reads", "host_writes", "controller_busy_time",
	"power_cycles", "power_on_hours", "unsafe_shutdowns", "media_errors",
	"num_err_log_entries",
}

var nvmeLogLabels = map[string]string{
	"nsid":                      "命名空间标识",
	"critical_warning":          "临界警告字节",
	"temperature":               "当前温度",
	"available_spare":           "可用备用空间",
	"available_spare_threshold": "备用空间告警阈值",
	"percentage_used":           "寿命已用百分比",
	"data_units_read":           "累计读取数据单元",
	"data_units_written":        "累计写入数据单元",
	"host_reads":                "主机读取命令数",
	"host_writes":               "主机写入命令数",
	"controller_busy_time":      "控制器忙时长",
	"power_cycles":              "通电次数",
	"power_on_hours":            "累计通电时长",
	"unsafe_shutdowns":          "异常断电次数",
	"media_errors":              "介质与数据完整性错误数",
	"num_err_log_entries":       "错误日志条目数",
}

var capabilityLabels = map[string]string{
	"security_send_receive":        "安全命令收发",
	"format_nvm":                   "格式化 NVM",
	"firmware_download":            "固件下载与更新",
	"namespace_management":         "命名空间管理",
	"self_test":                    "设备自检",
	"directives":                   "指令集扩展",
	"mi_send_receive":              "管理接口命令收发",
	"virtualization_management":    "虚拟化管理",
	"doorbell_buffer_config":       "门铃缓冲配置",
	"get_lba_status":               "读取逻辑块状态",
	"command_and_feature_lockdown": "命令与特性锁定",
	"compare":                      "比较命令",
	"write_uncorrectable":          "写入不可校正标记",
	"dataset_management":           "数据集管理",
	"write_zeroes":                 "写零命令",
	"save_select_feature_nonzero":  "保存选定特性",
	"reservations":                 "预留命令",
	"timestamp":                    "时间戳特性",
	"verify":                       "校验命令",
	"copy":                         "复制命令",
	"smart_health_per_namespace":   "按命名空间的健康日志",
	"commands_effects_log":         "命令效果日志",
	"extended_get_log_page_cmd":    "扩展日志页读取命令",
	"telemetry_log":                "遥测日志",
	"persistent_event_log":         "持久化事件日志",
	"supported_log_pages_log":      "受支持日志页清单",
	"telemetry_data_area_4":        "遥测数据区 4",
	"slots":                        "固件槽位数量",
	"first_slot_is_read_only":      "首个槽位为只读",
	"activiation_without_reset":    "无需复位即可激活固件",
	"multiple_update_detection":    "多次更新检测",
	"other":                        "其他未定义位",
	"value":                        "原始位值",
	"non_operational_state":        "非运行电源状态",
	"relative_read_latency":        "相对读取延迟等级",
	"relative_read_throughput":     "相对读取吞吐等级",
	"relative_write_latency":       "相对写入延迟等级",
	"relative_write_throughput":    "相对写入吞吐等级",
	"entry_latency_us":             "进入该状态延迟",
	"exit_latency_us":              "退出该状态延迟",
	"max_power":                    "最大功耗",
}

var ataAttrNames = map[int]string{
	1: "读取错误率", 2: "吞吐性能", 3: "起转时间", 4: "启停次数",
	5: "重映射扇区数", 6: "读取通道余量", 7: "寻道错误率", 8: "寻道时间性能",
	9: "累计通电时长", 10: "起转重试次数", 11: "重新校准重试次数", 12: "通电次数",
	13: "软读取错误率", 100: "擦除/编程周期数", 170: "可用备用空间",
	171: "编程失败次数", 172: "擦除失败次数", 174: "意外掉电次数",
	175: "程序失败块数", 176: "擦除失败块数", 177: "磨损均衡计数",
	178: "已用备用块数", 179: "已用总备用块数", 180: "未用备用块总数",
	181: "编程失败总数", 182: "擦除失败总数", 183: "运行时坏块数",
	184: "端到端错误数", 187: "无法校正错误数", 188: "命令超时次数",
	190: "气流温度", 191: "冲击错误率", 192: "断电缩回次数",
	193: "磁头加载/卸载次数", 194: "温度", 195: "硬件 ECC 已校正数",
	196: "重映射事件数", 197: "待映射扇区数", 198: "离线无法校正扇区数",
	199: "接口 CRC 错误数", 200: "多区域错误率", 201: "软读取错误率",
	202: "数据地址标记错误", 203: "运行时 ECC 错误", 204: "软 ECC 校正数",
	206: "飞行高度", 220: "震动冲击", 225: "累计写入数据量",
	231: "剩余寿命指示", 232: "可用预留空间", 233: "介质磨损指示",
	234: "累计读取数据量", 235: "磨损均衡计数", 241: "累计写入逻辑块数",
	242: "累计读取逻辑块数", 250: "读取错误重试率",
}

var cwBits = []string{
	"可用备用空间已低于阈值",
	"温度超过或低于允许范围",
	"可靠性下降（介质或内部完整性受损）",
	"介质已进入只读模式",
	"易失性内存备份设备故障",
}

var exitBits = []struct {
	bit  int
	text string
}{
	{1, "命令行参数解析失败"},
	{2, "设备打开失败（设备可能未连接或权限不足）"},
	{4, "部分 SMART 或日志命令执行失败（数据可能不完整）"},
	{8, "磁盘健康自检结果为失败"},
	{16, "检测到预失败属性（有属性超过阈值）"},
	{32, "历史记录中曾出现预失败属性"},
	{64, "错误日志中存在记录"},
	{128, "自检日志中存在错误"},
}

func ProtocolLabel(protocol, typ string) string {
	switch strings.ToUpper(protocol) {
	case "NVME":
		return "NVMe（高速固态硬盘接口）"
	case "ATA", "SATA":
		return "SATA/ATA（串行硬盘接口）"
	case "SCSI", "SAS":
		return "SAS/SCSI（企业级硬盘接口）"
	case "USB":
		return "USB（通用串行总线）"
	}
	switch strings.ToLower(typ) {
	case "nvme":
		return "NVMe（高速固态硬盘接口）"
	case "sat", "ata":
		return "SATA/ATA（串行硬盘接口）"
	case "scsi":
		return "SAS/SCSI（企业级硬盘接口）"
	}
	if protocol != "" {
		return protocol + "（设备接口）"
	}
	return "未知接口"
}

func FormatCount(v float64) string {
	s := strconv.FormatFloat(v, 'f', 0, 64)
	parts := strings.Split(s, ".")
	sign := ""
	if strings.HasPrefix(parts[0], "-") {
		sign, parts[0] = "-", parts[0][1:]
	}
	n := len(parts[0])
	var b strings.Builder
	for i, r := range parts[0] {
		if i > 0 && (n-i)%3 == 0 {
			b.WriteRune(',')
		}
		b.WriteRune(r)
	}
	return sign + b.String()
}

// FormatBytes 使用二进制（IEC）换算，与全项目字节单位口径一致：
// 1 TiB = 1024^4 字节，单位统一显示为 B / KiB / MiB / GiB / TiB / PiB。
func FormatBytes(b float64) string {
	units := []string{"B", "KiB", "MiB", "GiB", "TiB", "PiB"}
	v := b
	i := 0
	for v >= 1024 && i < len(units)-1 {
		v /= 1024
		i++
	}
	return fmt.Sprintf("%.2f %s", v, units[i])
}

// FormatDataUnits NVMe 的 1 个数据单元 = 1000 × 512 字节。
func FormatDataUnits(n float64) string {
	return fmt.Sprintf("%s 个数据单元（约 %s）", FormatCount(n), FormatBytes(n*512000))
}

func FormatHours(h float64) string {
	if h < 24 {
		return fmt.Sprintf("%s 小时", FormatCount(h))
	}
	days := h / 24
	if days < 365 {
		return fmt.Sprintf("%s 小时（约 %.1f 天）", FormatCount(h), days)
	}
	return fmt.Sprintf("%s 小时（约 %.1f 天，约 %.1f 年）", FormatCount(h), days, days/365)
}

func FormatTemperature(c float64) string {
	return fmt.Sprintf("%.0f 摄氏度", c)
}

func FormatPercent(v float64) string {
	return fmt.Sprintf("%.0f%%", v)
}

func FormatLocalTime(m map[string]any) string {
	if sec := numIn(m, "time_t"); sec > 0 {
		local := time.Unix(int64(sec), 0).Local()
		week := []string{"星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"}[int(local.Weekday())]
		return fmt.Sprintf("%d 年 %d 月 %d 日 %s %s（本地时间）",
			local.Year(), int(local.Month()), local.Day(), week, local.Format("15:04:05"))
	}
	if s, ok := m["asctime"].(string); ok && s != "" {
		return TranslateDate(s)
	}
	return "未提供"
}

func TranslateDate(s string) string {
	days := [][2]string{{"Mon", "星期一"}, {"Tue", "星期二"}, {"Wed", "星期三"}, {"Thu", "星期四"}, {"Fri", "星期五"}, {"Sat", "星期六"}, {"Sun", "星期日"}}
	months := [][2]string{{"Jan", "1 月"}, {"Feb", "2 月"}, {"Mar", "3 月"}, {"Apr", "4 月"}, {"May", "5 月"}, {"Jun", "6 月"}, {"Jul", "7 月"}, {"Aug", "8 月"}, {"Sep", "9 月"}, {"Oct", "10 月"}, {"Nov", "11 月"}, {"Dec", "12 月"}}
	for _, p := range append(days, months...) {
		s = strings.ReplaceAll(s, p[0], p[1])
	}
	s = strings.ReplaceAll(s, "CST", "中国标准时间")
	return strings.Join(strings.Fields(s), " ")
}

// CriticalWarningNotes 逐位解释 NVMe 临界警告字节。
func CriticalWarningNotes(bits int) []string {
	if bits == 0 {
		return []string{"0x00（无任何临界警告）"}
	}
	var out []string
	for i, text := range cwBits {
		if bits&(1<<i) != 0 {
			out = append(out, fmt.Sprintf("第 %d 位：%s", i, text))
		}
	}
	for i := len(cwBits); i < 8; i++ {
		if bits&(1<<i) != 0 {
			out = append(out, fmt.Sprintf("第 %d 位：保留位被置位（厂商自定义含义）", i))
		}
	}
	return out
}

// ExitStatusNotes 把 smartctl 的位掩码退出码翻译成中文说明。
func ExitStatusNotes(code int) []string {
	if code == 0 {
		return []string{"退出码 0：所有检查全部成功，没有异常"}
	}
	out := []string{fmt.Sprintf("退出码 %d：以下状态位被置位", code)}
	for _, b := range exitBits {
		if code&b.bit != 0 {
			out = append(out, "· "+b.text)
		}
	}
	return out
}

var messagePhrases = [][2]string{
	{"Read ", "读取 "},
	{" entries from Error Information Log failed", " 条错误信息日志失败"},
	{" entries from Error Information Log", " 条错误信息日志"},
	{"GetLogPage failed", "读取日志页（GetLogPage）失败"},
	{"Read SMART Data failed", "读取 SMART 数据失败"},
	{"Device open failed", "打开设备失败"},
	{"Permission denied", "权限不足"},
	{"SMART support is: Unavailable", "设备不支持 SMART"},
	{"Unknown USB bridge", "无法识别的 USB 桥接芯片"},
	{"Error Information Log", "错误信息日志"},
	{"Self-test Log", "自检日志"},
	{"system=", "系统错误码 "},
	{"sub=", "子系统错误码 "},
	{"code=", "错误码 "},
	{"failed", "失败"},
	{"Failed", "失败"},
	{"error", "错误"},
}

// TranslateMessage 把 smartctl 的英文提示译为中文，技术错误码原样保留。
func TranslateMessage(msg string) string {
	s := msg
	for _, p := range messagePhrases {
		s = strings.ReplaceAll(s, p[0], p[1])
	}
	s = strings.ReplaceAll(s, ": ", "：")
	return "smartctl 提示：" + s
}

func capabilityName(key string) string {
	if v, ok := capabilityLabels[key]; ok {
		return v
	}
	return fmt.Sprintf("厂商定义项（%s）", key)
}

func ataAttrName(id int, english string) string {
	if v, ok := ataAttrNames[id]; ok {
		return v
	}
	if english != "" && english != "Unknown_Attribute" {
		return fmt.Sprintf("厂商自定义属性 %d", id)
	}
	return fmt.Sprintf("属性 %d（厂商定义）", id)
}

func numIn(m map[string]any, key string) float64 {
	if m == nil {
		return 0
	}
	switch v := m[key].(type) {
	case float64:
		return v
	case int:
		return float64(v)
	case int64:
		return float64(v)
	case string:
		f, _ := strconv.ParseFloat(v, 64)
		return f
	}
	return 0
}

func obj(m map[string]any, key string) map[string]any {
	if v, ok := m[key].(map[string]any); ok {
		return v
	}
	return nil
}

func arr(m map[string]any, key string) []any {
	if v, ok := m[key].([]any); ok {
		return v
	}
	return nil
}

func str(m map[string]any, key string) string {
	if v, ok := m[key].(string); ok {
		return v
	}
	if v, ok := m[key].(float64); ok {
		return FormatCount(v)
	}
	return ""
}

func boolCN(v any) string {
	if b, ok := v.(bool); ok && b {
		return "是"
	}
	return "否"
}

func hexCN(v float64) string {
	return fmt.Sprintf("0x%04X（十进制 %s）", int(v), FormatCount(v))
}

func maxStatus(a, b string) string {
	rank := map[string]int{"info": 0, "ok": 1, "warn": 2, "critical": 3}
	if rank[b] > rank[a] {
		return b
	}
	return a
}

func containsAny(s string, words ...string) bool {
	for _, w := range words {
		if strings.Contains(s, w) {
			return true
		}
	}
	return false
}

// supportedList 把能力位字段里为真的项翻译成中文列表，忽略原始位值字段。
func supportedList(m map[string]any) string {
	var names []string
	for k, v := range m {
		if k == "value" || k == "other" {
			continue
		}
		if b, ok := v.(bool); ok && b {
			names = append(names, capabilityName(k))
		}
	}
	sort.Strings(names)
	if len(names) == 0 {
		return "无（该设备未启用额外能力）"
	}
	return strings.Join(names, "、")
}

// stringify 把任意 JSON 值转成中文可读文本，用于展示 smartctl 新增的未知字段。
func stringify(v any) string {
	switch t := v.(type) {
	case nil:
		return "无"
	case bool:
		return boolCN(t)
	case float64:
		return FormatCount(t)
	case string:
		return t
	case []any:
		parts := make([]string, 0, len(t))
		for _, x := range t {
			parts = append(parts, stringify(x))
		}
		if len(parts) == 0 {
			return "无"
		}
		return strings.Join(parts, "、")
	case map[string]any:
		keys := make([]string, 0, len(t))
		for k := range t {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		parts := make([]string, 0, len(keys))
		for _, k := range keys {
			parts = append(parts, capabilityName(k)+"："+stringify(t[k]))
		}
		if len(parts) == 0 {
			return "无"
		}
		return strings.Join(parts, "；")
	}
	return fmt.Sprint(v)
}
