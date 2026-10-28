#!/bin/sh

# 安装进度显示函数
show_progress() {
    echo "=============================================="
    echo "  $1"
    echo "=============================================="
}

# 停止旧服务
if [ -f "/etc/init.d/fancontrol" ]; then
    /etc/init.d/fancontrol stop 2>/dev/null
fi
killall fan_control 2>/dev/null

# 清理旧文件防止冲突
show_progress "清理旧版本文件"
rm -f /usr/bin/sensors_monitor /usr/bin/set_fan_speed /usr/bin/fan_control \
      /usr/lib/lua/luci/controller/sensors.lua /usr/lib/lua/luci/view/sensors_monitor.htm \
      /etc/fan_target /etc/fan_config /etc/init.d/fancontrol

# 检测并安装 PWM-Fan 驱动
show_progress "检测 PWM-Fan 驱动"

PWM_FAN_PATH="/sys/devices/platform/pwm-fan"

install_pwm_fan() {
    echo "尝试安装 kmod-pwm-fan 驱动 (可能需要几分钟)..."
    # opkg update 会导致部分无网设备卡死，这里建议用户自行 update
    if opkg install kmod-pwm-fan 2>/dev/null; then
        echo "kmod-pwm-fan 软件包安装成功，加载模块..."
        modprobe pwm-fan 2>/dev/null
        sleep 2
    else
        echo "kmod-pwm-fan 安装失败，请确保网络通畅并执行 opkg update"
    fi
}

if [ -d "$PWM_FAN_PATH" ]; then
    echo "✅ PWM-Fan 平台设备已就绪"
else
    echo "⚠️ 未检测到 PWM-Fan 平台设备，尝试加载驱动..."
    modprobe pwm-fan 2>/dev/null
    sleep 2

    if [ -d "$PWM_FAN_PATH" ]; then
        echo "✅ PWM-Fan 驱动加载成功"
    else
        install_pwm_fan
        if [ ! -d "$PWM_FAN_PATH" ]; then
            echo "=============================================="
            echo "  ❌ PWM-Fan 驱动安装失败，无法继续"
            echo "=============================================="
            exit 1
        fi
        echo "✅ PWM-Fan 驱动安装并加载成功"
    fi
fi

# 检查 PWM 控制节点
PWM_NODE=$(find /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1 -type f 2>/dev/null | head -1)
if [ -n "$PWM_NODE" ]; then
    echo "✅ PWM 控制节点: $PWM_NODE"
else
    echo "=============================================="
    echo "  ❌ PWM 控制节点未找到，无法继续"
    echo "=============================================="
    exit 1
fi
echo ""

# 创建监控脚本（输出JSON格式）
show_progress "创建传感器监控脚本"
cat > /usr/bin/sensors_monitor << 'EOF'
#!/bin/sh
# sensors_monitor — 采集系统传感器并输出 JSON 格式

PWM_FILE=${PWM_FILE:-$(find /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1 -type f 2>/dev/null | head -1)}

{
  echo "{"

  # CPU 温度
  cpu_raw=$(cat /sys/devices/virtual/thermal/thermal_zone0/temp 2>/dev/null)
  [ -n "$cpu_raw" ] && cpu_temp=$(( cpu_raw/1000 )) || cpu_temp="N/A"
  echo "\"cpu_temp\": \"$cpu_temp\","

  # 5GHz WiFi 温度
  wifi5_raw=$(cat /sys/class/hwmon/hwmon*/temp1_input 2>/dev/null | sort -rn | head -1)
  [ -n "$wifi5_raw" ] && wifi5_temp=$(( wifi5_raw/1000 )) || wifi5_temp="N/A"
  echo "\"wifi5_temp\": \"$wifi5_temp\","

  # 2.4GHz WiFi 温度
  wifi2_raw=$(cat /sys/class/hwmon/hwmon*/temp1_input 2>/dev/null | sort -n | head -1)
  [ -n "$wifi2_raw" ] && wifi2_temp=$(( wifi2_raw/1000 )) || wifi2_temp="N/A"
  echo "\"wifi2_temp\": \"$wifi2_temp\","

  # 读取所有 5G 模组温度
  MODEM_TEMPS=$(/usr/libexec/rpcd/modem_ctrl call info 2>/dev/null | grep -A1 '"key": "temperature"' | grep '"value":' | cut -d'"' -f4 | grep -oE '[0-9]+')
  modem1_temp="N/A"
  modem2_temp="N/A"
  idx=1
  for t in $MODEM_TEMPS; do
    if [ "$idx" -eq 1 ]; then modem1_temp=$t; fi
    if [ "$idx" -eq 2 ]; then modem2_temp=$t; fi
    idx=$((idx+1))
  done
  
  echo "\"modem1_temp\": \"$modem1_temp\","
  echo "\"modem2_temp\": \"$modem2_temp\","

  # 计算最高温度 (仅依据双 5G 模块)
  max_temp=0
  for t in "$modem1_temp" "$modem2_temp"; do
    if [ "$t" != "N/A" ] && [ "$t" -gt "$max_temp" ] 2>/dev/null; then
      max_temp=$t
    fi
  done
  [ "$max_temp" -eq 0 ] && max_temp="N/A"
  echo "\"max_temp\": \"$max_temp\","

  # 风扇百分比
  if [ -f /tmp/fan_current_speed ]; then
    fan_percent=$(cat /tmp/fan_current_speed)
  elif [ -n "$PWM_FILE" ] && [ -r "$PWM_FILE" ]; then
    pwm=$(cat "$PWM_FILE")
    fan_percent=$(( (pwm * 100 + 128) / 255 ))
  else
    fan_percent="N/A"
  fi
  echo "\"fan_percent\": \"$fan_percent\","

  # 读取配置文件
  if [ -f /etc/fan_config ]; then
    . /etc/fan_config
    echo "\"fan_target_temp\": \"${target_temp:-55}\","
    echo "\"fan_mode\": \"${mode:-auto}\","
    echo "\"interval\": \"${interval:-5}\","
    echo "\"step0_offset\": \"${step0_offset:--3}\","
    echo "\"step1_offset\": \"${step1_offset:-0}\", \"step1_speed\": \"${step1_speed:-15}\","
    echo "\"step2_offset\": \"${step2_offset:-2}\", \"step2_speed\": \"${step2_speed:-30}\","
    echo "\"step3_offset\": \"${step3_offset:-4}\", \"step3_speed\": \"${step3_speed:-45}\","
    echo "\"step4_offset\": \"${step4_offset:-6}\", \"step4_speed\": \"${step4_speed:-60}\","
    echo "\"step5_offset\": \"${step5_offset:-8}\", \"step5_speed\": \"${step5_speed:-80}\","
    echo "\"step6_offset\": \"${step6_offset:-12}\", \"step6_speed\": \"${step6_speed:-100}\""
  else
    echo "\"fan_target_temp\": \"55\", \"fan_mode\": \"auto\", \"interval\": \"5\","
    echo "\"step0_offset\": \"-3\","
    echo "\"step1_offset\": \"0\", \"step1_speed\": \"15\","
    echo "\"step2_offset\": \"2\", \"step2_speed\": \"30\","
    echo "\"step3_offset\": \"4\", \"step3_speed\": \"45\","
    echo "\"step4_offset\": \"6\", \"step4_speed\": \"60\","
    echo "\"step5_offset\": \"8\", \"step5_speed\": \"80\","
    echo "\"step6_offset\": \"12\", \"step6_speed\": \"100\""
  fi

  echo "}"
} | tr -d '\n'
EOF
chmod +x /usr/bin/sensors_monitor

# 创建硬件监控脚本 (手动设置转速)
show_progress "创建风扇控制脚本"
cat > /usr/bin/set_fan_speed << 'EOF'
#!/bin/sh
PWM_FILE=$(find /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1 -type f 2>/dev/null | head -1)
ENABLE_FILE="${PWM_FILE%pwm1}pwm1_enable"
[ -w "$ENABLE_FILE" ] && echo 1 > "$ENABLE_FILE" 2>/dev/null

if [ -z "$1" ] || ! echo "$1" | grep -qE '^[0-9]+$'; then
  echo '{"result":"error","message":"Invalid percentage"}'
  exit 1
fi
percent=$1
[ "$percent" -lt 0 ] && percent=0
[ "$percent" -gt 100 ] && percent=100

pwm_value=$(( (percent * 255 + 50) / 100 ))
if [ -n "$PWM_FILE" ] && [ -w "$PWM_FILE" ]; then
  echo "$pwm_value" > "$PWM_FILE"
fi

echo "{\"result\": \"success\", \"percentage\": $percent, \"pwm_value\": $pwm_value}"
EOF
chmod +x /usr/bin/set_fan_speed

# 创建温控守护脚本 (Procd托管版) - 仅抓取5G模块温度
show_progress "创建温控守护脚本"
cat << 'EOF' > /usr/bin/fan_control
#!/bin/sh

get_max_temp() {
    max_temp=0
    # 获取所有的 5G 模块温度输出
    MODEM_TEMPS=$(/usr/libexec/rpcd/modem_ctrl call info 2>/dev/null | grep -A1 '"key": "temperature"' | grep '"value":' | cut -d'"' -f4 | grep -oE '[0-9]+')
    
    # 遍历所有找到的温度，选取最大值
    for t in $MODEM_TEMPS; do
        [ -n "$t" ] && [ "$t" -gt "$max_temp" ] 2>/dev/null && max_temp=$t
    done
    
    echo $max_temp
}

while true; do
    [ -f "/etc/fan_config" ] && . /etc/fan_config
    
    if [ -z "$FAN_FILE" ] || [ ! -e "$FAN_FILE" ]; then
        FAN_FILE=$(find /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1 -type f 2>/dev/null | head -1)
    fi
    ENABLE_FILE="${FAN_FILE%pwm1}pwm1_enable"
    [ -w "$ENABLE_FILE" ] && echo 1 > "$ENABLE_FILE" 2>/dev/null

    if [ "${mode:-auto}" = "auto" ]; then
        current_temp=$(get_max_temp)
        diff=$((current_temp - ${target_temp:-55}))

        if [ "$diff" -ge "${step6_offset:-12}" ]; then
            step_speed=${step6_speed:-100}
        elif [ "$diff" -ge "${step5_offset:-8}" ]; then
            step_speed=${step5_speed:-80}
        elif [ "$diff" -ge "${step4_offset:-6}" ]; then
            step_speed=${step4_speed:-60}
        elif [ "$diff" -ge "${step3_offset:-4}" ]; then
            step_speed=${step3_speed:-45}
        elif [ "$diff" -ge "${step2_offset:-2}" ]; then
            step_speed=${step2_speed:-30}
        elif [ "$diff" -ge "${step1_offset:-0}" ]; then
            step_speed=${step1_speed:-15}
        elif [ "$diff" -ge "${step0_offset:--3}" ]; then
            step_speed=${min_speed:-0}
        else
            step_speed=0
        fi

        PWM_FILE="$FAN_FILE" /usr/bin/set_fan_speed "$step_speed" >/dev/null
        printf '%s\n' "$step_speed" > /tmp/fan_current_speed
    else
        manual_speed=$(cat /tmp/fan_manual_speed 2>/dev/null)
        if [ -n "$manual_speed" ] && [ -n "$FAN_FILE" ] && [ -w "$FAN_FILE" ]; then
            PWM_FILE="$FAN_FILE" /usr/bin/set_fan_speed "$manual_speed" >/dev/null
            printf '%s\n' "$manual_speed" > /tmp/fan_current_speed
        fi
    fi

    sleep ${interval:-5}
done
EOF
chmod +x /usr/bin/fan_control

# 创建 LuCI 后端控制器
show_progress "创建LuCI控制器"
cat << 'EOF' > /usr/lib/lua/luci/controller/sensors.lua
module("luci.controller.sensors", package.seeall)

function index()
    entry({"admin", "status", "sensors"}, template("sensors_monitor"), _("硬件监控"), 90)
    entry({"admin", "status", "sensors", "data"}, call("action_data"))
    entry({"admin", "status", "sensors", "setfan"}, call("action_setfan"))
    entry({"admin", "status", "sensors", "settemp"}, call("action_settemp"))
    entry({"admin", "status", "sensors", "setmode"}, call("action_setmode"))
    entry({"admin", "status", "sensors", "setstep"}, call("action_setstep"))
end

function action_data()
    luci.http.prepare_content("application/json")
    local status, result = pcall(function() return luci.sys.exec("/usr/bin/sensors_monitor") end)
    if status and result and result ~= "" then
        luci.http.write(result)
    else
        luci.http.write('{"cpu_temp":"N/A","max_temp":"N/A","fan_percent":"N/A","fan_target_temp":"55","fan_mode":"auto"}')
    end
end

function action_setfan()
    local http = require "luci.http"
    local sys  = require "luci.sys"
    local p = tonumber(http.formvalue("fan_percent"))
    if not p or p < 0 or p > 100 then
        return http.write_json({result="error", message="Invalid fan percentage"})
    end
    p = math.floor(p)
    os.execute("sed -i 's/^mode=.*/mode=manual/' /etc/fan_config")
    os.execute("printf '%s\\n' " .. p .. " > /tmp/fan_manual_speed")
    http.prepare_content("application/json")
    return http.write(sys.exec("/usr/bin/set_fan_speed " .. p .. " 2>/dev/null"))
end

function action_settemp()
    local http = require "luci.http"
    local temp = tonumber(http.formvalue("target_temp"))
    if not temp or temp < 40 or temp > 80 then
        return http.write_json({result="error", message="Invalid target temperature"})
    end
    temp = math.floor(temp)
    os.execute("sed -i 's/^target_temp=.*/target_temp=" .. temp .. "/' /etc/fan_config")
    return http.write_json({result="success", target_temp=temp})
end

function action_setmode()
    local http = require "luci.http"
    local mode = http.formvalue("mode")
    if mode == "auto" or mode == "manual" then
        os.execute(string.format("sed -i 's/^mode=.*/mode=%s/' /etc/fan_config", mode))
        http.prepare_content("application/json")
        if mode == "manual" then
            local fp = tonumber(http.formvalue("fan_percent")) or 50
            fp = math.max(0, math.min(100, math.floor(fp)))
            os.execute("printf '%s\\n' " .. fp .. " > /tmp/fan_manual_speed")
            return http.write(require("luci.sys").exec("/usr/bin/set_fan_speed " .. fp))
        else
            os.execute("rm -f /tmp/fan_manual_speed")
            http.write('{"result":"success"}')
        end
    end
end

function action_setstep()
    local http = require "luci.http"
    http.prepare_content("application/json")
    
    local cfg = "/etc/fan_config"
    local function update(key, val)
        if val then
            os.execute(string.format("grep -q '^%s=' %s && sed -i 's/^%s=.*/%s=%s/' %s || echo '%s=%s' >> %s",
                key, cfg, key, key, math.floor(val), cfg, key, math.floor(val), cfg))
        end
    end

    update("step0_offset", tonumber(http.formvalue("step0_offset")))
    for i=1, 6 do
        update("step"..i.."_offset", tonumber(http.formvalue("step"..i.."_offset")))
        update("step"..i.."_speed", tonumber(http.formvalue("step"..i.."_speed")))
    end
    http.write('{"result":"success"}')
end
EOF

# 创建 LuCI 视图模板
mkdir -p /usr/lib/lua/luci/view
show_progress "创建LuCI视图模板"
cat << 'EOF' > /usr/lib/lua/luci/view/sensors_monitor.htm
<%+header%>
<style>
* { box-sizing: border-box; }
@keyframes fadeUp { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: translateY(0); } }
@keyframes breathe { 0%,100% { opacity: 1; } 50% { opacity: 0.4; } }

.cbi-map { background: #fff; border-radius: 16px; padding: 28px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }
.cbi-map h2 { font-size: 20px; font-weight: 700; color: #111827; margin: 0 0 2px; }
.cbi-map .cbi-map-descr { color: #9ca3af; font-size: 13px; margin-bottom: 24px; }
.sensors-container { display: grid; grid-template-columns: repeat(4, 1fr); gap: 14px; }
.sensor-card { background: #fff; border-radius: 14px; padding: 22px 20px 18px; border: 1px solid #f0f0f0; position: relative; overflow: hidden; animation: fadeUp 0.3s ease both; }
.sensor-card::after { content: ''; position: absolute; top: 0; left: 0; right: 0; height: 3px; background: #3b82f6; }
.card-header { display: flex; align-items: center; margin-bottom: 16px; position: relative; z-index: 2; }
.card-icon { font-size: 20px; margin-right: 10px; width: 40px; height: 40px; display: flex; align-items: center; justify-content: center; background: #f8fafc; border-radius: 10px; border: 1px solid #f0f0f0; }
.card-title { font-size: 12px; font-weight: 600; color: #6b7280; text-transform: uppercase; }
.card-value-container { position: relative; height: 90px; display: flex; align-items: center; justify-content: center; }
.card-value { font-size: 42px; font-weight: 800; text-align: center; font-family: monospace; z-index: 2; color: #111827; line-height: 1; }
.card-unit { font-size: 16px; font-weight: 500; color: #9ca3af; margin-left: 1px; }

.temp-low { color: #2563eb; } .temp-medium { color: #d97706; } .temp-high { color: #dc2626; }
.max-temp-card { grid-column: 1 / -1; background: linear-gradient(135deg, #fffbeb 0%, #fef3c7 100%); }
.max-temp-card::after { background: linear-gradient(90deg, #f59e0b, #f97316) !important; }
.fan-card { grid-column: 1 / -1; } .fan-card::after { background: linear-gradient(90deg, #3b82f6, #8b5cf6) !important; }

.refresh-info { text-align: center; padding: 10px 16px; color: #9ca3af; font-size: 12px; background: #fafafa; border-radius: 10px; margin-top: 14px; border: 1px solid #f0f0f0; }
.status-indicator { display: inline-block; width: 7px; height: 7px; border-radius: 50%; margin-right: 6px; background: #22c55e; animation: breathe 2.5s infinite; }

.fan-control-container { width: 100%; padding: 20px 0 0; margin-top: 20px; border-top: 1px solid #f3f4f6; position: relative; z-index: 2; }
.fan-slider-container { display: flex; align-items: center; gap: 12px; margin-bottom: 18px; padding: 12px 16px; background: #f9fafb; border-radius: 12px; border: 1px solid #f3f4f6; }
.fan-slider { flex-grow: 1; height: 5px; -webkit-appearance: none; background: #e5e7eb; border-radius: 3px; }
.fan-slider::-webkit-slider-thumb { -webkit-appearance: none; width: 18px; height: 18px; border-radius: 50%; background: #3b82f6; cursor: pointer; border: 3px solid #fff; }

.temp-control-container { display: flex; gap: 16px; margin-top: 18px; background: #f9fafb; padding: 18px; border-radius: 12px; border: 1px solid #f3f4f6; }
.temp-control-item { flex: 1; min-width: 200px; }
.temp-input { width: 100%; padding: 9px 12px; border: 1px solid #e5e7eb; border-radius: 8px; font-family: monospace; }
.temp-set-btn { background: #3b82f6; color: #fff; border: none; padding: 9px 22px; border-radius: 8px; cursor: pointer; font-weight: 600; margin-top: 10px; }

.mode-switch { display: flex; gap: 8px; margin-top: 10px; }
.mode-btn { flex: 1; padding: 9px 14px; border: 1.5px solid #e5e7eb; border-radius: 8px; text-align: center; cursor: pointer; color: #6b7280; }
.mode-btn.active { background: #3b82f6; color: #fff; border-color: #3b82f6; }

.step-panel { margin-top: 18px; background: #f9fafb; border-radius: 12px; border: 1px solid #f3f4f6; }
.step-toggle { display: flex; justify-content: space-between; padding: 12px 16px; cursor: pointer; font-weight: 600; color: #059669; }
.step-content { padding: 16px; display: none; border-top: 1px solid #f3f4f6; }
.step-content.active { display: block; }
.step-table { width: 100%; border-collapse: collapse; }
.step-th { padding: 8px; text-align: center; color: #6b7280; font-size: 11px; }
.step-td { padding: 6px; text-align: center; border-bottom: 1px solid #f3f4f6; }
.step-badge { display: inline-flex; width: 24px; height: 24px; align-items: center; justify-content: center; border-radius: 6px; color: #fff; font-size: 12px; font-weight: bold; }
.s0 { background: #9ca3af; } .s1 { background: #10b981; } .s2 { background: #84cc16; } .s3 { background: #f59e0b; } .s4 { background: #f97316; } .s5 { background: #ef4444; } .s6 { background: #b91c1c; }
.step-input { width: 80px; padding: 6px; text-align: center; border: 1px solid #e5e7eb; border-radius: 6px; }
.step-set-btn { width: 100%; background: #059669; color: #fff; border: none; padding: 10px; border-radius: 8px; margin-top: 14px; cursor: pointer; }
.chart-bg { position: absolute; top: 0; left: 0; width: 100%; height: 100%; z-index: 1; opacity: 0.75; }

@media (max-width: 992px) { .sensors-container { grid-template-columns: repeat(2, 1fr); } }
@media (max-width: 576px) { .sensors-container { grid-template-columns: 1fr; } .temp-control-container { flex-direction: column; } }
</style>

<div class="cbi-map">
    <h2 name="content"><%:硬件状态监控%></h2>
    <div class="cbi-map-descr"><%:实时设备传感器数据 · 每5秒自动刷新 (仅依据双5G模块温度进行温控)%></div>
    <div class="sensors-container" id="sensors-container"></div>
    <div class="refresh-info">
        <span id="refresh-status"><span class="status-indicator"></span><span>实时更新中 - 最后刷新: <span id="last-update">--:--:--</span></span></span>
    </div>
</div>

<script>
const sensors = [
    { id: "cpu_temp", name: "CPU温度", unit: "℃", icon: "🔥", type: "temp" },
    { id: "wifi5_temp", name: "5GHz WiFi", unit: "℃", icon: "📶", type: "temp" },
    { id: "wifi2_temp", name: "2.4GHz WiFi", unit: "℃", icon: "📡", type: "temp" },
    { id: "modem1_temp", name: "5G模组 1", unit: "℃", icon: "📡", type: "temp" },
    { id: "modem2_temp", name: "5G模组 2", unit: "℃", icon: "📡", type: "temp" },
    { id: "max_temp", name: "最高温度 (仅控制5G)", unit: "℃", icon: "📈", type: "temp", class: "max-temp-card" },
    { id: "fan_percent", name: "风扇转速", unit: "%", icon: "🌀", type: "fan", class: "fan-card" }
];

const historyData = {};
sensors.forEach(s => historyData[s.id] = []);
const container = document.getElementById('sensors-container');

function initCards() {
    container.innerHTML = '';
    sensors.forEach(sensor => {
        const card = document.createElement('div');
        card.className = `sensor-card ${sensor.class || ''}`;
        card.id = `card-${sensor.id}`;
        
        let html = `
            <div class="card-header"><div class="card-icon">${sensor.icon}</div><div class="card-title">${sensor.name}</div></div>
            <div class="card-value-container"><canvas class="chart-bg" id="chart-${sensor.id}"></canvas><div class="card-value">--</div></div>
        `;
        
        if (sensor.type === 'fan') {
            html += `
                <div class="fan-control-container">
                    <div class="fan-slider-container">
                        <span>手动转速:</span>
                        <input type="range" min="0" max="100" value="0" class="fan-slider" id="fan-slider">
                        <span style="font-weight:bold; color:#3b82f6" id="fan-slider-value">0%</span>
                    </div>
                    <div class="temp-control-container">
                        <div class="temp-control-item">
                            <label style="font-size:12px;font-weight:bold;display:block;margin-bottom:6px">目标温度 (℃)</label>
                            <input type="number" min="40" max="80" value="55" class="temp-input" id="target-temp-input">
                            <button class="temp-set-btn" onclick="setTargetTemp()">设置温度</button>
                        </div>
                        <div class="temp-control-item">
                            <label style="font-size:12px;font-weight:bold;display:block;margin-bottom:6px">工作模式</label>
                            <div class="mode-switch">
                                <div class="mode-btn" data-mode="auto" onclick="setMode('auto')">自动控制</div>
                                <div class="mode-btn" data-mode="manual" onclick="setMode('manual')">手动控制</div>
                            </div>
                        </div>
                    </div>
                    <div class="step-panel">
                        <div class="step-toggle" onclick="document.getElementById('step-content').classList.toggle('active')">
                            <span>自动控制 · 7档位温差设置</span><span>▼</span>
                        </div>
                        <div class="step-content" id="step-content">
                            <table class="step-table">
                                <thead><tr><th class="step-th">档位</th><th class="step-th">温差 ≥ (°C)</th><th class="step-th">风扇转速 (%)</th></tr></thead>
                                <tbody id="step-tbody"></tbody>
                            </table>
                            <button class="step-set-btn" onclick="setStepParams()">保存档位设置</button>
                        </div>
                    </div>
                </div>`;
        }
        card.innerHTML = html;
        container.appendChild(card);
    });

    // 动态生成 6个运转档位 + 1个停转档位 的表格
    const tbody = document.getElementById('step-tbody');
    if(tbody) {
        let rows = '';
        for(let i=6; i>=1; i--) {
            rows += `<tr><td class="step-td"><span class="step-badge s${i}">${i}</span></td>
                     <td class="step-td"><input type="number" class="step-input" id="step${i}-offset"></td>
                     <td class="step-td"><input type="number" class="step-input" id="step${i}-speed"></td></tr>`;
        }
        rows += `<tr><td class="step-td"><span class="step-badge s0">停</span></td>
                 <td class="step-td"><input type="number" class="step-input" id="step0-offset"></td>
                 <td class="step-td" style="color:#9ca3af;font-size:12px;">风扇停转 (0%)</td></tr>`;
        tbody.innerHTML = rows;
    }

    const slider = document.getElementById('fan-slider');
    if(slider) {
        slider.addEventListener('input', function() { document.getElementById('fan-slider-value').textContent = this.value + '%'; });
        slider.addEventListener('change', function() { setMode('manual', this.value); });
    }
}

function drawChart(id, vals, max=80, min=20) {
    const cvs = document.getElementById(id); if(!cvs) return;
    const ctx = cvs.getContext('2d');
    cvs.width = cvs.parentElement.clientWidth; cvs.height = cvs.parentElement.clientHeight;
    ctx.clearRect(0, 0, cvs.width, cvs.height);
    if(vals.length < 2) return;
    
    ctx.beginPath();
    ctx.strokeStyle = id.includes('fan') ? 'rgba(99,102,241,0.5)' : 'rgba(59,130,246,0.5)';
    ctx.lineWidth = 2;
    const stepX = cvs.width / (vals.length - 1);
    vals.forEach((v, i) => {
        let val = v === 'N/A' ? min : Math.max(min, Math.min(max, v));
        let y = cvs.height - ((val - min) / (max - min)) * cvs.height;
        if(i===0) ctx.moveTo(0, y); else ctx.lineTo(i * stepX, y);
    });
    ctx.stroke();
}

function setTargetTemp() {
    const val = document.getElementById('target-temp-input').value;
    const xhr = new XMLHttpRequest();
    xhr.open('POST', '<%= url("admin/status/sensors/settemp") %>');
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.send('target_temp=' + val);
}

function setMode(mode, speed) {
    let fp = speed || document.getElementById('fan-slider').value;
    const xhr = new XMLHttpRequest();
    xhr.open('POST', '<%= url("admin/status/sensors/setmode") %>');
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.onload = () => fetchSensorData();
    xhr.send('mode=' + mode + '&fan_percent=' + fp);
}

function setStepParams() {
    let params = `step0_offset=${document.getElementById('step0-offset').value}`;
    for(let i=1; i<=6; i++) {
        params += `&step${i}_offset=${document.getElementById('step${i}-offset').value}&step${i}_speed=${document.getElementById('step${i}-speed').value}`;
    }
    const xhr = new XMLHttpRequest();
    xhr.open('POST', '<%= url("admin/status/sensors/setstep") %>');
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.send(params);
}

function updateCards(data) {
    sensors.forEach(s => {
        let v = data[s.id] ?? 'N/A';
        const c = document.getElementById(`card-${s.id}`);
        if(c) {
            let el = c.querySelector('.card-value');
            if(v !== 'N/A') {
                el.innerHTML = s.type==='fan' ? `${v}<span class="card-unit">%</span>` : `${v}<span class="card-unit">℃</span>`;
                if(s.type==='fan') {
                    if(document.activeElement !== document.getElementById('fan-slider')) {
                        document.getElementById('fan-slider').value = v;
                        document.getElementById('fan-slider-value').textContent = v + '%';
                    }
                    document.querySelectorAll('.mode-btn').forEach(b => b.classList.toggle('active', b.dataset.mode === data.fan_mode));
                    if(document.activeElement !== document.getElementById('target-temp-input')) {
                        document.getElementById('target-temp-input').value = data.fan_target_temp || 55;
                    }
                    if(document.activeElement.className !== 'step-input') {
                        document.getElementById('step0-offset').value = data.step0_offset || '-3';
                        for(let i=1; i<=6; i++) {
                            document.getElementById(`step${i}-offset`).value = data[`step${i}_offset`] || '';
                            document.getElementById(`step${i}-speed`).value = data[`step${i}_speed`] || '';
                        }
                    }
                }
                const numericValue = Number.parseInt(v, 10);
                if (Number.isFinite(numericValue)) historyData[s.id].push(numericValue);
                if(historyData[s.id].length > 30) historyData[s.id].shift();
                drawChart(`chart-${s.id}`, historyData[s.id], s.type==='fan'?100:80, s.type==='fan'?0:20);
            } else { el.innerHTML = 'N/A'; }
        }
    });

    document.getElementById('last-update').textContent = new Date().toTimeString().substring(0, 8);
}

function fetchSensorData() {
    const xhr = new XMLHttpRequest();
    xhr.open('GET', '<%= url("admin/status/sensors/data") %>');
    xhr.onload = () => {
        if (xhr.status !== 200) return;
        try { updateCards(JSON.parse(xhr.responseText)); } catch (error) { console.error('Invalid sensor response', error); }
    };
    xhr.onerror = () => console.error('Unable to fetch sensor data');
    xhr.send();
}

document.addEventListener('DOMContentLoaded', () => { initCards(); fetchSensorData(); setInterval(fetchSensorData, 5000); });
</script>
<%+footer%>
EOF

# 创建风扇配置文件
show_progress "创建默认配置文件"
cat << 'EOF' > /etc/fan_config
mode=auto
target_temp=55
interval=5
min_speed=0
step0_offset=-3
step1_offset=0
step1_speed=15
step2_offset=2
step2_speed=30
step3_offset=4
step3_speed=45
step4_offset=6
step4_speed=60
step5_offset=8
step5_speed=80
step6_offset=12
step6_speed=100
EOF

# 创建现代 Procd 初始化服务
show_progress "创建 procd 开机启动服务"
cat << 'EOF' > /etc/init.d/fancontrol
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=99
STOP=10

start_service() {
    # 加载模块
    modprobe pwm-fan 2>/dev/null
    
    # 清理遗留的临时控制文件
    rm -f /tmp/fan_manual_speed /tmp/fan_current_speed 2>/dev/null

    # 使用 procd 托管监控脚本
    procd_open_instance
    procd_set_param command /usr/bin/fan_control
    procd_set_param respawn 3600 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    rm -f /tmp/fan_manual_speed /tmp/fan_current_speed 2>/dev/null
}
EOF
chmod +x /etc/init.d/fancontrol

# 启用并启动服务
show_progress "启动风扇控制服务 (双5G专版)"
/etc/init.d/fancontrol enable
/etc/init.d/fancontrol restart

# 重启uhttpd服务加载LuCI
/etc/init.d/uhttpd restart

echo "=============================================="
echo " ✅ 温控重构版 (双5G模块定制版) 安装完成"
echo "----------------------------------------------"
echo " 🌟 核心改进："
echo "  1. 风扇控制逻辑已修改为：仅响应 5G 模块的发热情况"
echo "  2. 已添加双 5G 模块读取，取两者最高温度控制风扇"
echo "  3. 面板数据保留了 CPU/WiFi 显示供参考，去除了硬盘唤醒逻辑"
echo "----------------------------------------------"
echo " 访问路径: 刷新 LuCI -> 状态 -> 硬件监控"
echo "=============================================="