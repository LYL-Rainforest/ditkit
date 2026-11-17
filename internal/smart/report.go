package smart

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"
)

const (
	StatusInfo     = "info"
	StatusOK       = "ok"
	StatusWarn     = "warn"
	StatusCritical = "critical"
)

// Row 是已经翻译成中文的一行信息，SwiftUI 侧不需要再做任何本地化。
type Row struct {
	Label  string `json:"label"`
	Value  string `json:"value"`
	Status string `json:"status"`
	Note   string `json:"note,omitempty"`
}

type Section struct {
	Title string `json:"title"`
	Rows  []Row  `json:"rows"`
}

type Report struct {
	Device      Disk      `json:"device"`
	Overall     string    `json:"overall"`
	Status      string    `json:"status"`
	Summary     string    `json:"summary"`
	GeneratedAt string    `json:"generated_at"`
	Sections    []Section `json:"sections"`
	Warnings    []string  `json:"warnings"`
	Messages    []string  `json:"messages"`
	ExitCode    int       `json:"exit_code"`
	ExitNotes   []string  `json:"exit_notes"`
}

// BuildReport 把 smartctl 的 JSON 完整展开为简体中文报告。
func BuildReport(disk Disk, raw []byte) (Report, error) {
	var d map[string]any
	if err := json.Unmarshal(raw, &d); err != nil {
		return Report{}, fmt.Errorf("解析 smartctl 输出: %w", err)
	}
	// 所有切片初始化为空数组而非 nil，避免 JSON 输出 null 导致 Swift 侧解码失败。
	r := Report{
		Device: disk, Status: StatusOK,
		GeneratedAt: time.Now().Format("2006 年 01 月 02 日 15:04:05"),
		Sections:    []Section{},
		Warnings:    []string{},
		Messages:    []string{},
		ExitNotes:   []string{},
	}
	tool := obj(d, "smartctl")
	r.ExitCode = int(numIn(tool, "exit_status"))
	r.ExitNotes = append(r.ExitNotes, ExitStatusNotes(r.ExitCode)...)
	for _, m := range arr(tool, "messages") {
		if mm, ok := m.(map[string]any); ok {
			r.Messages = append(r.Messages, TranslateMessage(str(mm, "string")))
		}
	}

	log := obj(d, "nvme_smart_health_information_log")
	appendSection(&r, sectionDevice(d))
	appendSection(&r, sectionOverall(d, log, &r))
	if log != nil {
		appendSection(&r, sectionNVMeLog(log, &r))
	}
	appendSection(&r, sectionPowerStates(d))
	if ata := obj(d, "ata_smart_attributes"); ata != nil {
		appendSection(&r, sectionATAAttributes(ata, &r))
	}
	appendSection(&r, sectionLogs(d, &r))
	appendSection(&r, sectionOther(d))
	appendSection(&r, sectionTool(d, &r))

	if r.ExitCode&4 != 0 {
		r.Warnings = append(r.Warnings, "部分 SMART 或日志命令执行失败，本次报告可能不完整（详见退出码说明）")
	}
	switch r.Status {
	case StatusCritical:
		r.Overall = "异常"
		r.Summary = "磁盘存在严重健康问题，建议立即备份数据并更换设备"
	case StatusWarn:
		r.Overall = "需要注意"
		r.Summary = "磁盘存在告警项，建议缩短巡检间隔并准备替换盘"
	default:
		r.Overall = "健康"
		r.Summary = "未发现 SMART 健康异常，各项指标处于正常范围"
	}
	if len(r.Warnings) > 0 && r.Status == StatusOK {
		r.Summary += "；但存在需要留意的提示项"
	}
	renumber(r.Sections)
	return r, nil
}

// renumber 让实际展示的分区编号连续，避免出现「四」之后直接跳到「八」。
func renumber(sections []Section) {
	numbers := []string{"一", "二", "三", "四", "五", "六", "七", "八", "九", "十"}
	for i := range sections {
		parts := strings.SplitN(sections[i].Title, "、", 2)
		name := parts[len(parts)-1]
		n := fmt.Sprintf("%d", i+1)
		if i < len(numbers) {
			n = numbers[i]
		}
		sections[i].Title = n + "、" + name
	}
}

func appendSection(r *Report, s Section) {
	if len(s.Rows) > 0 {
		r.Sections = append(r.Sections, s)
	}
}

func row(label, value, status, note string) Row {
	return Row{Label: label, Value: value, Status: status, Note: note}
}

func raise(r *Report, status, warning string) {
	r.Status = maxStatus(r.Status, status)
	if warning != "" {
		r.Warnings = append(r.Warnings, warning)
	}
}

func tempStatus(c float64) string {
	switch {
	case c >= 70:
		return StatusCritical
	case c >= 60:
		return StatusWarn
	default:
		return StatusOK
	}
}

func spareStatus(cur, threshold float64) string {
	switch {
	case cur < threshold:
		return StatusCritical
	case cur == threshold:
		return StatusWarn
	default:
		return StatusOK
	}
}

func enduranceStatus(p float64) string {
	switch {
	case p >= 100:
		return StatusCritical
	case p >= 80:
		return StatusWarn
	default:
		return StatusOK
	}
}

func sectionDevice(d map[string]any) Section {
	dev := obj(d, "device")
	nv := obj(d, "nvme_version")
	vendor := obj(d, "nvme_pci_vendor")
	support := obj(d, "smart_support")
	fw := obj(d, "nvme_firmware_update_capabilities")

	rows := []Row{
		row("设备路径", str(dev, "name"), StatusInfo, "smartctl 实际访问的设备标识"),
		row("接口类型", ProtocolLabel(str(dev, "protocol"), str(dev, "type")), StatusInfo, ""),
		row("设备型号", str(d, "model_name"), StatusOK, ""),
		row("序列号", str(d, "serial_number"), StatusInfo, ""),
		row("固件版本", str(d, "firmware_version"), StatusInfo, ""),
		row("本地时间", FormatLocalTime(obj(d, "local_time")), StatusInfo, "读取 SMART 数据时的系统时间"),
	}
	if nv != nil {
		rows = append(rows, row("NVMe 规范版本", str(nv, "string"), StatusInfo, "控制器遵循的 NVMe 协议版本"))
	}
	if v, ok := d["nvme_number_of_namespaces"]; ok {
		rows = append(rows, row("命名空间数量", FormatCount(numIn(map[string]any{"v": v}, "v"))+" 个", StatusInfo, ""))
	}
	if vendor != nil {
		rows = append(rows, row("PCI 厂商标识", hexCN(numIn(vendor, "id")), StatusInfo, ""),
			row("PCI 子系统标识", hexCN(numIn(vendor, "subsystem_id")), StatusInfo, ""))
	}
	if v, ok := d["nvme_ieee_oui_identifier"]; ok {
		rows = append(rows, row("IEEE 组织唯一标识", hexCN(numIn(map[string]any{"v": v}, "v")), StatusInfo, ""))
	}
	if v, ok := d["nvme_controller_id"]; ok {
		rows = append(rows, row("控制器编号", FormatCount(numIn(map[string]any{"v": v}, "v")), StatusInfo, ""))
	}
	if support != nil {
		rows = append(rows, row("SMART 功能支持", boolCN(support["available"]), StatusInfo, ""),
			row("SMART 功能已启用", boolCN(support["enabled"]), StatusInfo, ""))
	}
	if v, ok := d["nvme_maximum_data_transfer_pages"]; ok {
		rows = append(rows, row("最大数据传输页数", FormatCount(numIn(map[string]any{"v": v}, "v"))+" 页", StatusInfo, ""))
	}
	if fw != nil {
		rows = append(rows,
			row("固件更新槽位数", FormatCount(numIn(fw, "slots"))+" 个", StatusInfo, ""),
			row("首个槽位只读", boolCN(fw["first_slot_is_read_only"]), StatusInfo, ""),
			row("固件免复位激活", boolCN(fw["activiation_without_reset"]), StatusInfo, ""),
			row("多次固件更新检测", boolCN(fw["multiple_update_detection"]), StatusInfo, ""))
	}
	if c := obj(d, "nvme_optional_admin_commands"); c != nil {
		rows = append(rows, row("支持的可选管理命令", supportedList(c), StatusInfo, ""))
	}
	if c := obj(d, "nvme_optional_nvm_commands"); c != nil {
		rows = append(rows, row("支持的可选 NVM 命令", supportedList(c), StatusInfo, ""))
	}
	if c := obj(d, "nvme_log_page_attributes"); c != nil {
		rows = append(rows, row("支持的日志页能力", supportedList(c), StatusInfo, ""))
	}
	return Section{Title: "一、设备信息", Rows: rows}
}

func sectionOverall(d, log map[string]any, r *Report) Section {
	ss := obj(d, "smart_status")
	rows := []Row{}
	if ss == nil {
		// 部分 NVMe / USB 磁盘不提供 overall SMART status；缺失不等于「未通过」。
		rows = append(rows, row("SMART 总体自检", "该设备未提供", StatusInfo, ""))
	} else if passed, ok := ss["passed"].(bool); ok && passed {
		rows = append(rows, row("SMART 总体自检", "通过", StatusOK, "磁盘自检结果正常"))
	} else if ok {
		rows = append(rows, row("SMART 总体自检", "未通过", StatusCritical, "磁盘自检结果异常"))
		raise(r, StatusCritical, "SMART 总体自检未通过")
	} else {
		rows = append(rows, row("SMART 总体自检", "该设备未提供", StatusInfo, ""))
	}
	cw := int(numIn(log, "critical_warning"))
	cwStatus := StatusOK
	if cw != 0 {
		cwStatus = StatusCritical
		raise(r, StatusCritical, "NVMe 临界警告字节非零")
	}
	rows = append(rows, row("临界警告字节", fmt.Sprintf("0x%02X", cw), cwStatus,
		strings.Join(CriticalWarningNotes(cw), "；")))

	if t := obj(d, "temperature"); t != nil {
		temp := numIn(t, "current")
		rows = append(rows, row("当前温度", FormatTemperature(temp), tempStatus(temp), "超过 60 摄氏度需留意"))
		if tempStatus(temp) == StatusCritical {
			raise(r, StatusCritical, "温度达到危险水平")
		}
	} else {
		rows = append(rows, row("当前温度", "该设备未提供", StatusInfo, ""))
	}

	if spare := obj(d, "spare_available"); spare != nil {
		cur, th := numIn(spare, "current_percent"), numIn(spare, "threshold_percent")
		rows = append(rows, row("可用备用空间", FormatPercent(cur), spareStatus(cur, th),
			"告警阈值 "+FormatPercent(th)))
		if spareStatus(cur, th) == StatusCritical {
			raise(r, StatusCritical, "可用备用空间低于阈值")
		}
	} else {
		rows = append(rows, row("可用备用空间", "该设备未提供（通常为 NVMe 专有字段）", StatusInfo, ""))
	}

	if e := obj(d, "endurance_used"); e != nil {
		used := numIn(e, "current_percent")
		rows = append(rows, row("寿命已用百分比", FormatPercent(used), enduranceStatus(used),
			"厂商估算值，不代表精确剩余时间"))
		if enduranceStatus(used) == StatusCritical {
			raise(r, StatusCritical, "寿命已用达到或超过 100%")
		} else if enduranceStatus(used) == StatusWarn {
			raise(r, StatusWarn, "寿命已用超过 80%")
		}
	} else {
		rows = append(rows, row("寿命已用百分比", "该设备未提供", StatusInfo, ""))
	}
	if _, ok := d["power_cycle_count"]; ok {
		rows = append(rows, row("通电次数", FormatCount(numIn(d, "power_cycle_count"))+" 次", StatusInfo, ""))
	}
	if p := obj(d, "power_on_time"); p != nil {
		rows = append(rows, row("累计通电时长", FormatHours(numIn(p, "hours")), StatusInfo, ""))
	}
	return Section{Title: "二、总体健康", Rows: rows}
}

func sectionNVMeLog(log map[string]any, r *Report) Section {
	rows := []Row{}
	threshold := numIn(log, "available_spare_threshold")
	for _, key := range nvmeLogOrder {
		if _, exists := log[key]; !exists {
			continue
		}
		n := numIn(log, key)
		label := nvmeLogLabels[key]
		value, status, note := "", StatusOK, ""
		switch key {
		case "nsid":
			value = "全部命名空间（0xFFFFFFFF）"
			if n >= 0 {
				value = "命名空间 " + FormatCount(n)
			}
			status = StatusInfo
		case "critical_warning":
			value = fmt.Sprintf("0x%02X", int(n))
			note = strings.Join(CriticalWarningNotes(int(n)), "；")
			if n != 0 {
				status = StatusCritical
			}
		case "temperature":
			value, status, note = FormatTemperature(n), tempStatus(n), "控制器报告的温度"
		case "available_spare":
			value, status, note = FormatPercent(n), spareStatus(n, threshold), "与告警阈值比较"
		case "available_spare_threshold":
			value, status = FormatPercent(n), StatusInfo
		case "percentage_used":
			value, status, note = FormatPercent(n), enduranceStatus(n), "寿命消耗估算"
		case "data_units_read", "data_units_written":
			value, status = FormatDataUnits(n), StatusInfo
		case "host_reads", "host_writes":
			value, status = FormatCount(n)+" 次", StatusInfo
		case "controller_busy_time":
			value, status = FormatCount(n)+" 分钟", StatusInfo
		case "power_cycles":
			value, status = FormatCount(n)+" 次", StatusInfo
		case "power_on_hours":
			value, status, note = FormatHours(n), StatusInfo, "累计通电时间"
		case "unsafe_shutdowns":
			value, status, note = FormatCount(n)+" 次", StatusInfo, "非零表示曾意外断电，不等于磁盘故障"
			if n > 0 {
				note += "；建议检查供电与关机流程"
			}
		case "media_errors":
			value, status, note = FormatCount(n)+" 次", StatusOK, "非零表示介质或数据完整性出错"
			if n > 0 {
				status = StatusCritical
				raise(r, StatusCritical, "检测到介质与数据完整性错误")
			}
		case "num_err_log_entries":
			value, status, note = FormatCount(n)+" 条", StatusInfo, "控制器错误日志记录数"
			if n > 0 {
				status = StatusWarn
				raise(r, StatusWarn, "错误日志存在记录")
			}
		default:
			value, status = stringify(log[key]), StatusInfo
		}
		rows = append(rows, row(label, value, status, note))
	}
	for _, k := range sortedKeys(log) {
		if _, known := nvmeLogLabels[k]; known {
			continue
		}
		rows = append(rows, row("附加字段 · "+capabilityName(k), stringify(log[k]), StatusInfo,
			"smartctl 新增字段，已按中文键名展开"))
	}
	return Section{Title: "三、NVMe 健康信息明细", Rows: rows}
}

func sectionPowerStates(d map[string]any) Section {
	states := arr(d, "nvme_power_states")
	rows := []Row{}
	for i, item := range states {
		ps, ok := item.(map[string]any)
		if !ok {
			continue
		}
		mp := obj(ps, "max_power")
		units := numIn(mp, "units_per_watt")
		if units <= 0 {
			units = 1
		}
		watts := numIn(mp, "value") * numIn(mp, "scale") / units
		descs := []string{
			"最大功耗 " + fmt.Sprintf("%.2f 瓦特", watts),
			"进入延迟 " + FormatCount(numIn(ps, "entry_latency_us")) + " 微秒",
			"退出延迟 " + FormatCount(numIn(ps, "exit_latency_us")) + " 微秒",
			"非运行状态：" + boolCN(ps["non_operational_state"]),
			"相对写吞吐等级 " + FormatCount(numIn(ps, "relative_write_throughput")),
		}
		rows = append(rows, row(fmt.Sprintf("电源状态 %d", i), strings.Join(descs, "；"), StatusInfo, ""))
	}
	return Section{Title: "四、电源状态", Rows: rows}
}

func sectionATAAttributes(ata map[string]any, r *Report) Section {
	table := arr(ata, "table")
	rows := []Row{}
	for _, item := range table {
		e, ok := item.(map[string]any)
		if !ok {
			continue
		}
		id := int(numIn(e, "id"))
		name := ataAttrName(id, str(e, "name"))
		raw := obj(e, "raw")
		whenFailed := str(e, "when_failed")
		status, note := StatusOK, ""
		switch whenFailed {
		case "FAILING_NOW", "now", "failed_now":
			status, note = StatusCritical, "当前已超出阈值"
			raise(r, StatusCritical, name+" 当前超出阈值")
		case "In_the_past", "past":
			status, note = StatusWarn, "历史上曾超出阈值"
			raise(r, StatusWarn, name+" 历史上曾超出阈值")
		default:
			note = "未超出阈值"
		}
		value := fmt.Sprintf("当前值 %s，最差值 %s，阈值 %s，原始值 %s",
			FormatCount(numIn(e, "value")), FormatCount(numIn(e, "worst")),
			FormatCount(numIn(e, "thresh")), FormatCount(numIn(raw, "value")))
		rows = append(rows, row(name, value, status, note))
	}
	if rev := obj(ata, "revision"); rev != nil {
		rows = append(rows, row("属性表版本", stringify(rev), StatusInfo, ""))
	}
	return Section{Title: "五、ATA/SATA 属性表", Rows: rows}
}

func sectionLogs(d map[string]any, r *Report) Section {
	rows := []Row{}
	if e := obj(d, "ata_smart_error_log"); e != nil {
		summary := obj(e, "summary")
		count := numIn(summary, "error_count")
		status := StatusOK
		if count > 0 {
			status = StatusWarn
			raise(r, StatusWarn, "ATA 错误日志存在记录")
		}
		rows = append(rows, row("ATA 错误日志条数", FormatCount(count)+" 条", status, ""))
	}
	if e := obj(d, "ata_smart_self_test_log"); e != nil {
		rows = append(rows, row("ATA 自检日志", stringify(obj(e, "summary")), StatusInfo, ""))
	}
	return Section{Title: "六、错误与自检日志", Rows: rows}
}

var handledTopKeys = map[string]bool{
	"json_format_version": true, "smartctl": true, "local_time": true, "device": true,
	"model_name": true, "serial_number": true, "firmware_version": true,
	"nvme_pci_vendor": true, "nvme_ieee_oui_identifier": true, "nvme_controller_id": true,
	"nvme_version": true, "nvme_number_of_namespaces": true, "smart_support": true,
	"nvme_firmware_update_capabilities": true, "nvme_optional_admin_commands": true,
	"nvme_optional_nvm_commands": true, "nvme_log_page_attributes": true,
	"nvme_maximum_data_transfer_pages": true, "nvme_power_states": true,
	"smart_status": true, "nvme_smart_health_information_log": true,
	"temperature": true, "spare_available": true, "endurance_used": true,
	"power_cycle_count": true, "power_on_time": true,
	"ata_smart_attributes": true, "ata_smart_error_log": true, "ata_smart_self_test_log": true,
}

// sectionOther 兜底展示 smartctl 未来新增的所有顶层字段，保证「详细、不漏项」。
func sectionOther(d map[string]any) Section {
	rows := []Row{}
	for _, k := range sortedKeys(d) {
		if handledTopKeys[k] {
			continue
		}
		rows = append(rows, row(capabilityName(k), stringify(d[k]), StatusInfo, "smartctl 附加字段"))
	}
	return Section{Title: "七、其他信息", Rows: rows}
}

func sectionTool(d map[string]any, r *Report) Section {
	tool := obj(d, "smartctl")
	version := arr(tool, "version")
	ver := "未知"
	if len(version) >= 2 {
		ver = fmt.Sprintf("%s.%s", stringify(version[0]), stringify(version[1]))
	}
	argv := arr(tool, "argv")
	args := make([]string, 0, len(argv))
	for _, a := range argv {
		args = append(args, stringify(a))
	}
	rows := []Row{
		row("采集工具", "smartctl "+ver, StatusInfo, "S.M.A.R.T. 磁盘检测工具"),
		row("工具修订版本", str(tool, "svn_revision"), StatusInfo, ""),
		row("运行平台", translatePlatform(str(tool, "platform_info")), StatusInfo, ""),
		row("JSON 数据格式版本", stringify(d["json_format_version"]), StatusInfo, ""),
		row("命令退出码", fmt.Sprintf("%d", r.ExitCode)+"（含义见下方）", StatusInfo, ""),
		row("执行的命令", strings.Join(args, " "), StatusInfo, "参数由程序固定构造，不接受用户输入拼接"),
	}
	return Section{Title: "八、采集工具信息", Rows: rows}
}

func translatePlatform(s string) string {
	s = strings.ReplaceAll(s, "Darwin", "macOS Darwin")
	s = strings.ReplaceAll(s, "arm64", "（Apple 芯片 arm64 架构）")
	s = strings.ReplaceAll(s, "x86_64", "（Intel/AMD 64 位架构）")
	return s
}

func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
