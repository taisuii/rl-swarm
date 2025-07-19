#!/bin/bash

# RL-Swarm 监控脚本
# 用于监控 rl-swarm 进程状态，自动重启异常退出的进程

set -euo pipefail

# 配置参数
ROOT_DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"
SCRIPT_NAME="run_rl_swarm.sh"
LOG_DIR="$ROOT_DIR/logs"
MONITOR_LOG="$LOG_DIR/monitor.log"
PID_FILE="$ROOT_DIR/rl_swarm.pid"
RESTART_LOG="$LOG_DIR/restart_history.log"
CHECK_INTERVAL=30  # 检查间隔（秒）
RESTART_DELAY=10  # 重启延迟（秒）
REAL_TIME_MODE=false  # 实时模式标志

# 安全配置参数
MAX_RESTART_COUNT=5  # 最大重启次数
MAX_RESTART_WINDOW=3600  # 重启时间窗口（秒，1小时）
MEMORY_THRESHOLD=85  # 内存使用阈值（百分比）
CPU_THRESHOLD=90  # CPU使用阈值（百分比）
COOLDOWN_PERIOD=300  # 冷却期（秒，5分钟）
HEALTH_CHECK_TIMEOUT=60  # 健康检查超时（秒）
FORCE_KILL_TIMEOUT=30  # 强制终止超时（秒）
STABLE_RUN_TIME=600  # 稳定运行时间（秒，10分钟）

# 颜色输出
GREEN_TEXT="\033[32m"
BLUE_TEXT="\033[34m"
RED_TEXT="\033[31m"
YELLOW_TEXT="\033[33m"
RESET_TEXT="\033[0m"

echo_green() {
    echo -e "$GREEN_TEXT$1$RESET_TEXT"
}

echo_blue() {
    echo -e "$BLUE_TEXT$1$RESET_TEXT"
}

echo_red() {
    echo -e "$RED_TEXT$1$RESET_TEXT"
}

echo_yellow() {
    echo -e "$YELLOW_TEXT$1$RESET_TEXT"
}

# 记录日志（支持实时输出）
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="[$timestamp] $message"
    
    # 总是写入日志文件
    echo "$log_entry" >> "$MONITOR_LOG"
    
    # 如果是实时模式，也输出到控制台
    if [ "$REAL_TIME_MODE" = true ]; then
        echo_blue "$log_entry"
    fi
}

# 实时跟踪日志文件
tail_logs() {
    echo_green ">> 开始实时监控日志输出..."
    echo_yellow ">> 按 Ctrl+C 停止监控"
    echo ""
    
    # 创建一个临时文件来跟踪多个日志
    local temp_log="/tmp/rl_swarm_combined.log"
    
    # 后台任务：合并多个日志文件
    (
        while true; do
            {
                if [ -f "$LOG_DIR/rl_swarm_output.log" ]; then
                    tail -n 0 -f "$LOG_DIR/rl_swarm_output.log" 2>/dev/null | sed 's/^/[RL-SWARM] /' &
                fi
                
                if [ -f "$LOG_DIR/yarn.log" ]; then
                    tail -n 0 -f "$LOG_DIR/yarn.log" 2>/dev/null | sed 's/^/[YARN] /' &
                fi
                
                if [ -f "$MONITOR_LOG" ]; then
                    tail -n 0 -f "$MONITOR_LOG" 2>/dev/null | sed 's/^/[MONITOR] /' &
                fi
                
                wait
            }
            sleep 1
        done
    ) &
    
    local tail_pid=$!
    
    # 捕获中断信号
    trap "kill $tail_pid 2>/dev/null; exit 0" INT TERM
    
    # 等待用户中断
    wait $tail_pid
}

# 创建必要的目录
mkdir -p "$LOG_DIR"

# 清理函数
cleanup() {
    echo_yellow ">> 监控脚本正在退出..."
    
    # 如果有运行的 rl-swarm 进程，询问是否要停止
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo_yellow ">> 检测到运行中的 rl-swarm 进程 (PID: $pid)"
            read -p "是否要停止该进程? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                stop_rl_swarm
            fi
        fi
    fi
    
    log_message "监控脚本已退出"
    exit 0
}

# 捕获退出信号
trap cleanup EXIT INT TERM

# 停止 rl-swarm 进程（改进版）
stop_rl_swarm() {
    echo_yellow ">> 正在停止 rl-swarm 进程..."
    
    local pids_to_kill=()
    
    # 收集需要终止的进程PID
    if [ -f "$PID_FILE" ]; then
        local main_pid=$(cat "$PID_FILE")
        if kill -0 "$main_pid" 2>/dev/null; then
            pids_to_kill+=("$main_pid")
        fi
    fi
    
    # 查找相关进程
    local related_pids
    related_pids=$(pgrep -f "python -m rgym_exp.runner.swarm_launcher" 2>/dev/null || true)
    [ -n "$related_pids" ] && pids_to_kill+=($(echo $related_pids))
    
    related_pids=$(pgrep -f "yarn start" 2>/dev/null || true)
    [ -n "$related_pids" ] && pids_to_kill+=($(echo $related_pids))
    
    related_pids=$(pgrep -f "node.*modal-login" 2>/dev/null || true)
    [ -n "$related_pids" ] && pids_to_kill+=($(echo $related_pids))
    
    related_pids=$(pgrep -f "run_rl_swarm.sh" 2>/dev/null || true)
    [ -n "$related_pids" ] && pids_to_kill+=($(echo $related_pids))
    
    if [ ${#pids_to_kill[@]} -eq 0 ]; then
        echo_green ">> 没有发现运行中的 rl-swarm 进程"
        rm -f "$PID_FILE"
        return 0
    fi
    
    # 优雅终止
    echo_blue ">> 尝试优雅终止进程..."
    for pid in "${pids_to_kill[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "   终止进程 $pid"
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    
    # 等待进程退出
    local wait_count=0
    while [ $wait_count -lt $FORCE_KILL_TIMEOUT ]; do
        local still_running=false
        for pid in "${pids_to_kill[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                still_running=true
                break
            fi
        done
        
        if [ "$still_running" = false ]; then
            break
        fi
        
        sleep 1
        wait_count=$((wait_count + 1))
    done
    
    # 强制终止仍在运行的进程
    for pid in "${pids_to_kill[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            echo_yellow "   强制终止进程 $pid"
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done
    
    # 最终等待
    sleep 2
    
    # 清理 PID 文件
    rm -f "$PID_FILE"
    
    log_message "rl-swarm 进程已停止"
    echo_green ">> rl-swarm 进程已完全停止"
}

# 启动 rl-swarm
start_rl_swarm() {
    echo_green ">> 正在启动 rl-swarm..."
    
    cd "$ROOT_DIR"
    
    # 检查并激活虚拟环境
    if ! check_and_activate_venv; then
        echo_red ">> 虚拟环境激活失败，但将继续尝试启动"
        log_message "虚拟环境激活失败，继续启动"
    fi
    
    # 设置必要的环境变量（与原始脚本保持一致）
    export IDENTITY_PATH
    export GENSYN_RESET_CONFIG
    export CONNECT_TO_TESTNET=true
    export ORG_ID
    export HF_HUB_DOWNLOAD_TIMEOUT=120
    export SWARM_CONTRACT="0xFaD7C5e93f28257429569B854151A1B8DCD404c2"
    export HUGGINGFACE_ACCESS_TOKEN="None"
    # 根据系统内存动态调整 PyTorch MPS 设置
    local total_memory_gb=16  # 默认值
    if command -v system_profiler >/dev/null 2>&1; then
        # macOS
        total_memory_gb=$(system_profiler SPHardwareDataType | grep "Memory:" | awk '{print $2}' | sed 's/GB//' 2>/dev/null || echo 16)
    elif [ -f /proc/meminfo ]; then
        # Linux
        total_memory_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 16)
    fi
    
    # 根据内存大小设置更保守的值
    if [ "$total_memory_gb" -le 16 ]; then
        export PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.1
        echo_yellow "   检测到 ${total_memory_gb}GB 内存，使用保守的 MPS 设置: 0.1"
    elif [ "$total_memory_gb" -le 32 ]; then
        export PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.2
        echo_blue "   检测到 ${total_memory_gb}GB 内存，使用适中的 MPS 设置: 0.2"
    else
        export PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.3
        echo_green "   检测到 ${total_memory_gb}GB 内存，使用标准的 MPS 设置: 0.3"
    fi
    
    # 设置默认路径
    DEFAULT_IDENTITY_PATH="$ROOT_DIR/swarm.pem"
    IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}
    
    DOCKER=${DOCKER:-""}
    GENSYN_RESET_CONFIG=${GENSYN_RESET_CONFIG:-""}
    CPU_ONLY=${CPU_ONLY:-""}
    ORG_ID=${ORG_ID:-""}
    
    # 检查必要文件是否存在
    if [ ! -f "$SCRIPT_NAME" ]; then
        echo_red ">> 错误: 找不到 $SCRIPT_NAME"
        return 1
    fi
    
    # 显示Python环境信息
    echo_blue ">> Python环境信息:"
    echo "   Python路径: $(which python)"
    echo "   Python版本: $(python --version 2>&1)"
    if [ -n "${VIRTUAL_ENV:-}" ]; then
        echo "   虚拟环境: $VIRTUAL_ENV"
    else
        echo "   虚拟环境: 未激活"
    fi
    echo "   PyTorch MPS设置: PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0"
    
    # 使用 bash 启动脚本，确保环境变量正确传递
    # 需要在激活虚拟环境的上下文中启动
    if [ -n "${VIRTUAL_ENV:-}" ]; then
        # 在虚拟环境中启动
        bash -c "source '$VIRTUAL_ENV/bin/activate' && export PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0 && bash '$SCRIPT_NAME'" > "$LOG_DIR/rl_swarm_output.log" 2>&1 &
    else
        # 直接启动
        bash -c "export PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0 && bash '$SCRIPT_NAME'" > "$LOG_DIR/rl_swarm_output.log" 2>&1 &
    fi
    
    local pid=$!
    
    # 保存 PID
    echo $pid > "$PID_FILE"
    
    log_message "rl-swarm 已启动 (PID: $pid)"
    echo_green ">> rl-swarm 已启动 (PID: $pid)"
    
    # 等待一段时间确保启动成功
    sleep $RESTART_DELAY
    
    # 验证进程是否真正启动
    if ! kill -0 "$pid" 2>/dev/null; then
        echo_red ">> 警告: 进程启动后立即退出，请检查日志"
        log_message "警告: 进程启动后立即退出"
        return 1
    fi
    
    return 0
}

# 检查进程是否运行
is_process_running() {
    if [ ! -f "$PID_FILE" ]; then
        return 1
    fi
    
    local pid=$(cat "$PID_FILE")
    if ! kill -0 "$pid" 2>/dev/null; then
        # PID 文件存在但进程不存在，清理 PID 文件
        rm -f "$PID_FILE"
        return 1
    fi
    
    # 检查是否是正确的进程（更宽松的检查）
    if ! pgrep -f "run_rl_swarm.sh" > /dev/null && ! pgrep -f "python -m rgym_exp.runner.swarm_launcher" > /dev/null; then
        # 如果两个关键进程都不存在，认为服务未运行
        rm -f "$PID_FILE"
        return 1
    fi
    
    return 0
}

# 检查日志中的错误
check_for_errors() {
    local error_patterns=(
        "killed"
        "An error was detected while running rl-swarm"
        "Traceback"
        "Error:"
        "Exception:"
        "SIGKILL"
        "SIGTERM"
    )
    
    # 检查最近的日志文件
    local log_files=(
        "$LOG_DIR/rl_swarm_output.log"
        "$LOG_DIR/yarn.log"
    )
    
    for log_file in "${log_files[@]}"; do
        if [ -f "$log_file" ]; then
            # 检查最近 50 行日志
            local recent_logs=$(tail -n 50 "$log_file" 2>/dev/null || echo "")
            
            for pattern in "${error_patterns[@]}"; do
                if echo "$recent_logs" | grep -qi "$pattern"; then
                    log_message "在 $log_file 中检测到错误模式: $pattern"
                    return 0
                fi
            done
        fi
    done
    
    return 1
}

# 检查系统资源
check_system_resources() {
    local memory_usage=0
    local cpu_usage=0
    
    # 检查内存使用率（跨平台）
    if command -v free >/dev/null 2>&1; then
        # Linux
        memory_usage=$(free | grep Mem | awk '{printf "%.0f", $3/$2 * 100.0}')
    elif command -v vm_stat >/dev/null 2>&1; then
        # macOS
        local page_size=$(vm_stat | grep "page size" | awk '{print $8}')
        local pages_free=$(vm_stat | grep "Pages free" | awk '{print $3}' | sed 's/\.//')
        local pages_active=$(vm_stat | grep "Pages active" | awk '{print $3}' | sed 's/\.//')
        local pages_inactive=$(vm_stat | grep "Pages inactive" | awk '{print $3}' | sed 's/\.//')
        local pages_speculative=$(vm_stat | grep "Pages speculative" | awk '{print $3}' | sed 's/\.//')
        local pages_wired=$(vm_stat | grep "Pages wired down" | awk '{print $4}' | sed 's/\.//')
        
        local total_pages=$((pages_free + pages_active + pages_inactive + pages_speculative + pages_wired))
        local used_pages=$((pages_active + pages_inactive + pages_wired))
        
        if [ $total_pages -gt 0 ]; then
            memory_usage=$((used_pages * 100 / total_pages))
        fi
    fi
    
    # 检查CPU使用率（跨平台）
    if command -v top >/dev/null 2>&1; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS
            cpu_usage=$(top -l 1 -n 0 | grep "CPU usage" | awk '{print $3}' | sed 's/%//')
        else
            # Linux
            cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | sed 's/%us,//')
        fi
    fi
    
    # 如果获取失败，设置默认值
    memory_usage=${memory_usage:-0}
    cpu_usage=${cpu_usage:-0}
    
    # 检查是否超过阈值
    if [ "$memory_usage" -gt "$MEMORY_THRESHOLD" ]; then
        log_message "警告: 内存使用率过高 ($memory_usage% > $MEMORY_THRESHOLD%)"
        return 1
    fi
    
    if [ "$cpu_usage" -gt "$CPU_THRESHOLD" ]; then
        log_message "警告: CPU使用率过高 ($cpu_usage% > $CPU_THRESHOLD%)"
        return 1
    fi
    
    return 0
}

# 检查重启频率
check_restart_frequency() {
    local current_time=$(date +%s)
    local restart_count=0
    
    # 创建重启历史文件如果不存在
    touch "$RESTART_LOG"
    
    # 清理过期的重启记录
    local cutoff_time=$((current_time - MAX_RESTART_WINDOW))
    grep -v "^[0-9]*$" "$RESTART_LOG" > /tmp/restart_temp || true
    awk -v cutoff="$cutoff_time" '$1 > cutoff' "$RESTART_LOG" > /tmp/restart_temp 2>/dev/null || true
    mv /tmp/restart_temp "$RESTART_LOG" 2>/dev/null || true
    
    # 计算当前时间窗口内的重启次数
    restart_count=$(wc -l < "$RESTART_LOG" 2>/dev/null || echo 0)
    
    if [ "$restart_count" -ge "$MAX_RESTART_COUNT" ]; then
        log_message "错误: 重启次数过多 ($restart_count/$MAX_RESTART_COUNT)，进入冷却期 ($COOLDOWN_PERIOD 秒)"
        echo_red ">> 重启次数过多，进入冷却期 $COOLDOWN_PERIOD 秒"
        sleep $COOLDOWN_PERIOD
        
        # 清空重启历史，给系统一个新的机会
        > "$RESTART_LOG"
        return 1
    fi
    
    return 0
}

# 记录重启
record_restart() {
    local current_time=$(date +%s)
    echo "$current_time" >> "$RESTART_LOG"
    log_message "记录重启时间: $(date -d @$current_time 2>/dev/null || date -r $current_time 2>/dev/null || date)"
}

# 健康检查
health_check() {
    if [ ! -f "$PID_FILE" ]; then
        return 1
    fi
    
    local pid=$(cat "$PID_FILE")
    if ! kill -0 "$pid" 2>/dev/null; then
        return 1
    fi
    
    # 检查进程是否响应（简单的活跃度检查）
    local log_file="$LOG_DIR/rl_swarm_output.log"
    if [ -f "$log_file" ]; then
        # 检查最近是否有日志输出（最近5分钟）
        local recent_activity=$(find "$log_file" -mmin -5 2>/dev/null)
        if [ -z "$recent_activity" ]; then
            log_message "警告: 进程可能无响应，最近5分钟无日志输出"
            return 1
        fi
    fi
    
    return 0
}

# 主监控循环（改进版）
monitor_loop() {
    local restart_count=0
    local real_time_flag="${1:-false}"
    local last_start_time=0
    local stable_start_time=0
    
    if [ "$real_time_flag" = "--real-time" ] || [ "$real_time_flag" = "-r" ]; then
        REAL_TIME_MODE=true
        echo_green ">> 实时监控模式已启用"
    fi
    
    echo_blue ">> RL-Swarm 智能监控脚本已启动"
    echo_blue ">> 检查间隔: ${CHECK_INTERVAL}秒"
    echo_blue ">> 最大重启次数: $MAX_RESTART_COUNT (${MAX_RESTART_WINDOW}秒内)"
    echo_blue ">> 内存阈值: $MEMORY_THRESHOLD%, CPU阈值: $CPU_THRESHOLD%"
    echo_blue ">> 日志文件: $MONITOR_LOG"
    
    if [ "$REAL_TIME_MODE" = true ]; then
        echo_green ">> 实时日志输出已启用"
    fi
    
    log_message "智能监控脚本已启动 (实时模式: $REAL_TIME_MODE, 安全重启模式: 启用)"
    
    # 如果是实时模式，启动日志跟踪
    if [ "$REAL_TIME_MODE" = true ]; then
        tail_logs &
        local tail_pid=$!
        trap "kill $tail_pid 2>/dev/null; cleanup" EXIT INT TERM
    fi
    
    while true; do
        local current_time=$(date +%s)
        
        # 检查系统资源
        if ! check_system_resources; then
            echo_yellow ">> 系统资源使用率过高，跳过此次检查"
            sleep $CHECK_INTERVAL
            continue
        fi
        
        if ! is_process_running; then
            echo_red ">> 检测到 rl-swarm 进程未运行"
            log_message "检测到 rl-swarm 进程未运行"
            
            # 检查重启频率
            if ! check_restart_frequency; then
                sleep $CHECK_INTERVAL
                continue
            fi
            
            restart_count=$((restart_count + 1))
            echo_yellow ">> 尝试重启 (第 $restart_count 次)"
            log_message "尝试重启 rl-swarm (第 $restart_count 次)"
            
            # 记录重启
            record_restart
            
            stop_rl_swarm
            sleep 5
            
            if start_rl_swarm; then
                echo_green ">> 重启成功"
                log_message "重启成功"
                last_start_time=$current_time
                stable_start_time=0
            else
                echo_red ">> 重启失败，将在下次检查时重试"
                log_message "重启失败"
            fi
        elif ! health_check; then
            echo_yellow ">> 健康检查失败，进程可能无响应"
            log_message "健康检查失败，进程可能无响应"
            
            # 只有在进程运行时间超过稳定期才考虑重启
            if [ $last_start_time -gt 0 ] && [ $((current_time - last_start_time)) -gt $STABLE_RUN_TIME ]; then
                if ! check_restart_frequency; then
                    sleep $CHECK_INTERVAL
                    continue
                fi
                
                restart_count=$((restart_count + 1))
                echo_yellow ">> 由于健康检查失败重启 (第 $restart_count 次)"
                log_message "由于健康检查失败重启 rl-swarm (第 $restart_count 次)"
                
                record_restart
                stop_rl_swarm
                start_rl_swarm
                last_start_time=$current_time
                stable_start_time=0
            fi
        elif check_for_errors; then
            echo_red ">> 检测到严重错误，准备重启进程"
            log_message "检测到严重错误，准备重启进程"
            
            # 只有在进程运行时间超过稳定期才考虑重启
            if [ $last_start_time -gt 0 ] && [ $((current_time - last_start_time)) -gt $STABLE_RUN_TIME ]; then
                if ! check_restart_frequency; then
                    sleep $CHECK_INTERVAL
                    continue
                fi
                
                restart_count=$((restart_count + 1))
                echo_yellow ">> 由于错误重启 (第 $restart_count 次)"
                log_message "由于错误重启 rl-swarm (第 $restart_count 次)"
                
                record_restart
                stop_rl_swarm
                start_rl_swarm
                last_start_time=$current_time
                stable_start_time=0
            fi
        else
            # 进程正常运行
            if [ $stable_start_time -eq 0 ] && [ $last_start_time -gt 0 ] && [ $((current_time - last_start_time)) -gt $STABLE_RUN_TIME ]; then
                stable_start_time=$current_time
                echo_green ">> 进程已稳定运行 $STABLE_RUN_TIME 秒"
                log_message "进程已稳定运行 $STABLE_RUN_TIME 秒"
            fi
            
            if [ "$REAL_TIME_MODE" = true ]; then
                local current_time_str=$(date '+%H:%M:%S')
                local uptime="未知"
                if [ $last_start_time -gt 0 ]; then
                    uptime="$((current_time - last_start_time))秒"
                fi
                echo_green "[$current_time_str] >> rl-swarm 运行正常 (运行时间: $uptime, 已重启 $restart_count 次)"
            fi
        fi
        
        sleep $CHECK_INTERVAL
    done
}

# 显示帮助信息
show_help() {
    echo "RL-Swarm 智能监控脚本 v2.0"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  start           启动智能监控"
    echo "  start --real-time 启动实时监控（直接输出日志）"
    echo "  start -r        启动实时监控（简写）"
    echo "  stop            停止 rl-swarm 进程"
    echo "  status          查看状态"
    echo "  restart         重启 rl-swarm 进程"
    echo "  logs            查看监控日志"
    echo "  tail            实时跟踪所有日志"
    echo "  help            显示此帮助信息"
    echo ""
    echo "智能监控特性:"
    echo "  ✓ 重启限制: 最多 $MAX_RESTART_COUNT 次/$((MAX_RESTART_WINDOW/60)) 分钟"
    echo "  ✓ 系统资源监控: 内存 <$MEMORY_THRESHOLD%, CPU <$CPU_THRESHOLD%"
    echo "  ✓ 健康检查: 检测进程响应性和日志活跃度"
    echo "  ✓ 稳定期保护: 启动后 $((STABLE_RUN_TIME/60)) 分钟内不会因错误重启"
    echo "  ✓ 冷却机制: 重启过多时自动冷却 $((COOLDOWN_PERIOD/60)) 分钟"
    echo "  ✓ 优雅终止: 先尝试 SIGTERM，超时后使用 SIGKILL"
    echo ""
    echo "Python虚拟环境:"
    echo "  脚本会自动检测并激活 .venv 虚拟环境"
    echo "  如果虚拟环境不存在，将使用系统Python环境"
    echo ""
    echo "环境变量:"
    echo "  动态调整 PYTORCH_MPS_HIGH_WATERMARK_RATIO (0.1-0.3)"
    echo "  根据系统内存大小自动优化设置"
    echo ""
    echo "日志文件:"
    echo "  监控日志: $MONITOR_LOG"
    echo "  重启历史: $RESTART_LOG"
    echo "  应用日志: $LOG_DIR/rl_swarm_output.log"
    echo ""
}

# 查看状态
show_status() {
    echo_blue ">> RL-Swarm 智能监控状态检查"
    
    # 显示监控配置
    echo ">> 监控配置:"
    echo "   检查间隔: ${CHECK_INTERVAL}秒"
    echo "   最大重启次数: $MAX_RESTART_COUNT 次/$((MAX_RESTART_WINDOW/60))分钟"
    echo "   内存阈值: $MEMORY_THRESHOLD%, CPU阈值: $CPU_THRESHOLD%"
    echo "   稳定运行时间: $((STABLE_RUN_TIME/60))分钟"
    echo ""
    
    # 显示系统资源状态
    echo ">> 系统资源状态:"
    local memory_usage=0
    local cpu_usage=0
    
    if command -v free >/dev/null 2>&1; then
        memory_usage=$(free | grep Mem | awk '{printf "%.0f", $3/$2 * 100.0}' 2>/dev/null || echo 0)
    elif command -v vm_stat >/dev/null 2>&1; then
        local page_size=$(vm_stat | grep "page size" | awk '{print $8}' 2>/dev/null || echo 4096)
        local pages_free=$(vm_stat | grep "Pages free" | awk '{print $3}' | sed 's/\.//' 2>/dev/null || echo 0)
        local pages_active=$(vm_stat | grep "Pages active" | awk '{print $3}' | sed 's/\.//' 2>/dev/null || echo 0)
        local pages_inactive=$(vm_stat | grep "Pages inactive" | awk '{print $3}' | sed 's/\.//' 2>/dev/null || echo 0)
        local pages_wired=$(vm_stat | grep "Pages wired down" | awk '{print $4}' | sed 's/\.//' 2>/dev/null || echo 0)
        
        local total_pages=$((pages_free + pages_active + pages_inactive + pages_wired))
        local used_pages=$((pages_active + pages_inactive + pages_wired))
        
        if [ $total_pages -gt 0 ]; then
            memory_usage=$((used_pages * 100 / total_pages))
        fi
    fi
    
    if command -v top >/dev/null 2>&1; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            cpu_usage=$(top -l 1 -n 0 | grep "CPU usage" | awk '{print $3}' | sed 's/%//' 2>/dev/null || echo 0)
        else
            cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | sed 's/%us,//' 2>/dev/null || echo 0)
        fi
    fi
    
    if [ "$memory_usage" -gt "$MEMORY_THRESHOLD" ]; then
        echo_red "   内存使用率: $memory_usage% (超过阈值 $MEMORY_THRESHOLD%)"
    else
        echo_green "   内存使用率: $memory_usage% (正常)"
    fi
    
    if [ "$cpu_usage" -gt "$CPU_THRESHOLD" ]; then
        echo_red "   CPU使用率: $cpu_usage% (超过阈值 $CPU_THRESHOLD%)"
    else
        echo_green "   CPU使用率: $cpu_usage% (正常)"
    fi
    echo ""
    
    # 显示重启历史
    if [ -f "$RESTART_LOG" ]; then
        local restart_count=$(wc -l < "$RESTART_LOG" 2>/dev/null || echo 0)
        local current_time=$(date +%s)
        local cutoff_time=$((current_time - MAX_RESTART_WINDOW))
        local recent_restarts=$(awk -v cutoff="$cutoff_time" '$1 > cutoff' "$RESTART_LOG" 2>/dev/null | wc -l || echo 0)
        
        echo ">> 重启历史:"
        echo "   最近 $((MAX_RESTART_WINDOW/60)) 分钟内重启次数: $recent_restarts/$MAX_RESTART_COUNT"
        
        if [ $recent_restarts -ge $MAX_RESTART_COUNT ]; then
            echo_red "   状态: 已达到重启限制"
        elif [ $recent_restarts -gt $((MAX_RESTART_COUNT/2)) ]; then
            echo_yellow "   状态: 重启频率较高"
        else
            echo_green "   状态: 重启频率正常"
        fi
        echo ""
    fi
    
    # 显示虚拟环境状态
    echo ">> Python环境状态:"
    if [ -n "${VIRTUAL_ENV:-}" ]; then
        echo_green "   虚拟环境: 已激活 ($VIRTUAL_ENV)"
    else
        if [ -d "$ROOT_DIR/.venv" ]; then
            echo_yellow "   虚拟环境: 存在但未激活 ($ROOT_DIR/.venv)"
        else
            echo_yellow "   虚拟环境: 不存在"
        fi
    fi
    echo "   Python路径: $(which python 2>/dev/null || echo '未找到')"
    echo "   Python版本: $(python --version 2>&1 || echo '无法获取版本')"
    
    # 显示 PyTorch MPS 设置
    if [ -n "${PYTORCH_MPS_HIGH_WATERMARK_RATIO:-}" ]; then
        echo "   PyTorch MPS 设置: $PYTORCH_MPS_HIGH_WATERMARK_RATIO"
    fi
    echo ""
    
    # 显示进程状态
    if is_process_running; then
        local pid=$(cat "$PID_FILE")
        echo_green ">> rl-swarm 正在运行 (PID: $pid)"
        
        # 计算运行时间
        if [ -f "$PID_FILE" ]; then
            local pid_file_time=$(stat -c %Y "$PID_FILE" 2>/dev/null || stat -f %m "$PID_FILE" 2>/dev/null || echo 0)
            local current_time=$(date +%s)
            local uptime=$((current_time - pid_file_time))
            local uptime_str=""
            
            if [ $uptime -ge 3600 ]; then
                uptime_str="$((uptime/3600))小时$((uptime%3600/60))分钟"
            elif [ $uptime -ge 60 ]; then
                uptime_str="$((uptime/60))分钟$((uptime%60))秒"
            else
                uptime_str="${uptime}秒"
            fi
            
            echo "   运行时间: $uptime_str"
            
            # 检查是否在稳定期
            if [ $uptime -lt $STABLE_RUN_TIME ]; then
                echo_yellow "   状态: 稳定期保护中 (剩余 $((STABLE_RUN_TIME - uptime)) 秒)"
            else
                echo_green "   状态: 稳定运行"
            fi
        fi
        
        # 健康检查
        if health_check; then
            echo_green "   健康检查: 通过"
        else
            echo_yellow "   健康检查: 警告 (进程可能无响应)"
        fi
        
        # 显示进程信息
        echo "   相关进程:"
        local python_pids=$(pgrep -f "python -m rgym_exp.runner.swarm_launcher" 2>/dev/null || true)
        if [ -n "$python_pids" ]; then
            echo "     Python进程: $python_pids"
        fi
        
        local yarn_pids=$(pgrep -f "yarn start" 2>/dev/null || true)
        if [ -n "$yarn_pids" ]; then
            echo "     Yarn进程: $yarn_pids"
        fi
    else
        echo_red ">> rl-swarm 未运行"
    fi
    
    # 显示最近的日志
    if [ -f "$MONITOR_LOG" ]; then
        echo ""
        echo ">> 最近的监控日志:"
        tail -n 3 "$MONITOR_LOG"
    fi
}

# 查看日志
show_logs() {
    if [ -f "$MONITOR_LOG" ]; then
        echo_blue ">> 监控日志 ($MONITOR_LOG):"
        tail -n 20 "$MONITOR_LOG"
    else
        echo_yellow ">> 监控日志文件不存在"
    fi
    
    echo ""
    
    if [ -f "$LOG_DIR/rl_swarm_output.log" ]; then
        echo_blue ">> RL-Swarm 输出日志:"
        tail -n 20 "$LOG_DIR/rl_swarm_output.log"
    else
        echo_yellow ">> RL-Swarm 输出日志文件不存在"
    fi
}

# 主函数
main() {
    case "${1:-start}" in
        "start")
            if [ "${2:-}" = "--real-time" ] || [ "${2:-}" = "-r" ]; then
                monitor_loop "--real-time"
            else
                monitor_loop
            fi
            ;;
        "stop")
            stop_rl_swarm
            ;;
        "status")
            show_status
            ;;
        "restart")
            stop_rl_swarm
            start_rl_swarm
            ;;
        "logs")
            show_logs
            ;;
        "tail")
            tail_logs
            ;;
        "help")
            show_help
            ;;
        *)
            echo_red ">> 未知选项: $1"
            show_help
            exit 1
            ;;
    esac
}

# 检查并激活Python虚拟环境
check_and_activate_venv() {
    local venv_path="$ROOT_DIR/.venv"
    
    # 检查是否已经在虚拟环境中
    if [ -n "${VIRTUAL_ENV:-}" ]; then
        echo_green ">> 已在虚拟环境中: $VIRTUAL_ENV"
        log_message "已在虚拟环境中: $VIRTUAL_ENV"
        return 0
    fi
    
    # 检查虚拟环境是否存在
    if [ ! -d "$venv_path" ]; then
        echo_yellow ">> 虚拟环境不存在，将在系统Python环境中运行"
        log_message "虚拟环境不存在: $venv_path"
        return 0
    fi
    
    # 检查激活脚本是否存在
    local activate_script="$venv_path/bin/activate"
    if [ ! -f "$activate_script" ]; then
        # Windows环境下的路径
        activate_script="$venv_path/Scripts/activate"
        if [ ! -f "$activate_script" ]; then
            echo_yellow ">> 虚拟环境激活脚本不存在，将在系统Python环境中运行"
            log_message "虚拟环境激活脚本不存在"
            return 0
        fi
    fi
    
    echo_green ">> 检测到虚拟环境，正在激活: $venv_path"
    log_message "激活虚拟环境: $venv_path"
    
    # 激活虚拟环境
    source "$activate_script"
    
    if [ -n "${VIRTUAL_ENV:-}" ]; then
        echo_green ">> 虚拟环境激活成功: $VIRTUAL_ENV"
        log_message "虚拟环境激活成功: $VIRTUAL_ENV"
        return 0
    else
        echo_red ">> 虚拟环境激活失败"
        log_message "虚拟环境激活失败"
        return 1
    fi
}

# 检查是否在正确的目录
if [ ! -f "$ROOT_DIR/$SCRIPT_NAME" ]; then
    echo_red ">> 错误: 在当前目录找不到 $SCRIPT_NAME"
    echo_red ">> 请确保在 rl-swarm 项目根目录运行此脚本"
    exit 1
fi

# 运行主函数
main "$@"