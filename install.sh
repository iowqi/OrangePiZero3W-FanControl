#!/bin/bash
# OrangePiZero3W-FanControl 一键安装脚本
# 用法: 在开发板上项目目录内执行  sudo bash install.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "[错误] 请以 root 运行: sudo bash install.sh"
    exit 1
fi

# 1. 检查 PWM 控制器是否可用(需要已启用 pwm0 overlay)
if [ ! -d /sys/class/pwm/pwmchip0 ]; then
    echo "[错误] 未找到 /sys/class/pwm/pwmchip0"
    echo "请先启用 PWM0 设备树 overlay(见 README「系统准备:启用 PWM0 overlay」一节),"
    echo "重启后重新执行本脚本。"
    exit 1
fi

# 2. 安装主程序与服务单元
echo "[1/3] 安装 pwm-fan.py -> /usr/local/sbin/pwm-fan.py"
install -m 0755 -o root -g root "$SCRIPT_DIR/pwm-fan.py" /usr/local/sbin/pwm-fan.py

echo "[2/3] 安装 pwm-fan.service -> /etc/systemd/system/pwm-fan.service"
install -m 0644 -o root -g root "$SCRIPT_DIR/pwm-fan.service" /etc/systemd/system/pwm-fan.service

# 3. 重载并启用(开机自启)
echo "[3/3] 重载 systemd 并启用服务"
systemctl daemon-reload
systemctl enable pwm-fan.service
systemctl restart pwm-fan.service

sleep 3

echo
echo "========== 安装完成 =========="
systemctl --no-pager status pwm-fan.service
echo
echo "常用命令:"
echo "  查看实时日志: journalctl -u pwm-fan -f"
echo "  查看当前状态: sudo /usr/local/sbin/pwm-fan.py --show"
echo "  手动测试风扇: sudo /usr/local/sbin/pwm-fan.py --test 50"
