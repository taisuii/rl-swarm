#!/bin/bash

# Mac系统彻底清理nvm、yarn、node脚本
# 使用方法: chmod +x cleanup.sh && ./cleanup.sh

set -e  # 遇到错误时停止执行

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 打印彩色信息
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否为macOS
check_macos() {
    if [[ "$OSTYPE" != "darwin"* ]]; then
        print_error "此脚本仅适用于macOS系统"
        exit 1
    fi
}

# 确认操作
confirm_cleanup() {
    echo -e "${YELLOW}⚠️  警告：此操作将彻底删除以下内容：${NC}"
    echo "   • nvm (Node Version Manager)"
    echo "   • Node.js (所有版本)"
    echo "   • npm (Node Package Manager)"
    echo "   • yarn (Yarn Package Manager)"
    echo "   • 相关的缓存和配置文件"
    echo ""
    read -p "确定要继续吗？[y/N]: " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "操作已取消"
        exit 0
    fi
}

# 安全删除函数
safe_remove() {
    if [[ -e "$1" ]]; then
        print_info "删除: $1"
        rm -rf "$1"
        print_success "已删除: $1"
    else
        print_warning "不存在: $1"
    fi
}

# 安全删除文件中的行
safe_remove_lines() {
    local file="$1"
    local pattern="$2"
    if [[ -f "$file" ]]; then
        if grep -q "$pattern" "$file"; then
            print_info "从 $file 中删除包含 '$pattern' 的行"
            sed -i '' "/$pattern/d" "$file"
            print_success "已从 $file 中清理相关配置"
        fi
    fi
}

# 1. 卸载nvm
cleanup_nvm() {
    print_info "开始清理 nvm..."
    
    # 删除nvm目录
    safe_remove "$HOME/.nvm"
    
    # 清理shell配置文件
    local config_files=("$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.bash_profile")
    for file in "${config_files[@]}"; do
        safe_remove_lines "$file" "NVM_DIR"
        safe_remove_lines "$file" "nvm.sh"
        safe_remove_lines "$file" "bash_completion"
    done
    
    print_success "nvm 清理完成"
}

# 2. 卸载Node.js
cleanup_node() {
    print_info "开始清理 Node.js..."
    
    # 删除node和npm相关文件
    local node_paths=(
        "/usr/local/bin/node"
        "/usr/local/bin/npm"
        "/usr/local/bin/npx"
        "/usr/local/lib/node_modules"
        "/usr/local/lib/node"
        "/usr/local/include/node"
        "/usr/local/share/man/man1/node*"
        "/opt/local/bin/node"
        "/opt/local/include/node"
        "/opt/local/lib/node_modules"
    )
    
    for path in "${node_paths[@]}"; do
        if [[ -e "$path" ]]; then
            print_info "删除: $path"
            sudo rm -rf "$path" 2>/dev/null || true
        fi
    done
    
    # 尝试通过Homebrew卸载
    if command -v brew &> /dev/null; then
        print_info "尝试通过Homebrew卸载node..."
        brew uninstall --ignore-dependencies node 2>/dev/null || true
        brew uninstall --force node 2>/dev/null || true
    fi
    
    print_success "Node.js 清理完成"
}

# 3. 卸载Yarn
cleanup_yarn() {
    print_info "开始清理 Yarn..."
    
    # 通过npm卸载yarn
    if command -v npm &> /dev/null; then
        print_info "尝试通过npm卸载yarn..."
        npm uninstall -g yarn 2>/dev/null || true
    fi
    
    # 通过Homebrew卸载yarn
    if command -v brew &> /dev/null; then
        print_info "尝试通过Homebrew卸载yarn..."
        brew uninstall yarn 2>/dev/null || true
    fi
    
    # 删除yarn相关文件
    safe_remove "$HOME/.yarn"
    safe_remove "/usr/local/bin/yarn"
    safe_remove "/usr/local/bin/yarnpkg"
    
    print_success "Yarn 清理完成"
}

# 4. 清理缓存和配置
cleanup_cache() {
    print_info "开始清理缓存和配置..."
    
    # 清理各种缓存
    local cache_dirs=(
        "$HOME/.npm"
        "$HOME/.node-gyp"
        "$HOME/.node_repl_history"
        "$HOME/.yarn-cache"
        "$HOME/.cache/yarn"
        "$HOME/Library/Caches/Yarn"
        "$HOME/.config/yarn"
    )
    
    for dir in "${cache_dirs[@]}"; do
        safe_remove "$dir"
    done
    
    print_success "缓存和配置清理完成"
}

# 5. 验证清理结果
verify_cleanup() {
    print_info "验证清理结果..."
    
    local commands=("node" "npm" "npx" "yarn" "nvm")
    local all_clean=true
    
    for cmd in "${commands[@]}"; do
        if command -v "$cmd" &> /dev/null; then
            print_error "$cmd 仍然存在: $(which $cmd)"
            all_clean=false
        else
            print_success "$cmd 已成功清理"
        fi
    done
    
    if $all_clean; then
        print_success "🎉 所有组件已成功清理！"
    else
        print_warning "⚠️  某些组件可能需要手动清理"
    fi
}

# 6. 重新加载shell配置
reload_shell() {
    print_info "重新加载shell配置..."
    
    # 重新加载配置文件
    if [[ -f "$HOME/.bashrc" ]]; then
        source "$HOME/.bashrc" 2>/dev/null || true
    fi
    if [[ -f "$HOME/.zshrc" ]]; then
        source "$HOME/.zshrc" 2>/dev/null || true
    fi
    
    print_success "shell配置已重新加载"
    print_info "建议重新打开终端以确保所有更改生效"
}

# 主函数
main() {
    echo "================================"
    echo "  Mac nvm/yarn/node 清理脚本"
    echo "================================"
    echo ""
    
    check_macos
    confirm_cleanup
    
    echo ""
    print_info "开始执行清理操作..."
    echo ""
    
    cleanup_nvm
    echo ""
    cleanup_node
    echo ""
    cleanup_yarn
    echo ""
    cleanup_cache
    echo ""
    verify_cleanup
    echo ""
    reload_shell
    
    echo ""
    echo "================================"
    print_success "✅ 清理完成！"
    echo "================================"
    echo ""
    print_info "如果需要重新安装，推荐使用以下方式之一："
    echo "  • 仅使用 nvm: curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash"
    echo "  • 仅使用 Homebrew: brew install node yarn"
    echo ""
    print_warning "避免混合安装方式，以防止版本冲突"
}

# 执行主函数
main "$@"
