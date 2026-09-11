#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Orange Pi Zero3W PWM 散热风扇温控脚本
=====================================
硬件: PB4 -> PWM0_0 (/sys/class/pwm/pwmchip0/pwm0), 占空比控制风扇转速

温控曲线(参数见下方, 可按需调整):
  温度 <= 35°C  -> 占空比 0%   (停转)
  温度 >= 60°C  -> 占空比 100% (全速)
  35 ~ 60°C     -> 线性插值

特性:
  * 滞回: 温度升过 36.5°C 才启动, 降到 35°C 以下才停转, 避免临界抖动
  * 起转保护: 启动瞬间以 100% 短促"踢一脚", 确保风扇可靠起转
  * 最低运行占空比 25%: 防止低占空比下风扇堵转/异响
  * EMA 平滑: 占空比渐变, 减少转速突变带来的噪音
  * 安全兜底: 读温失败或进程退出时, 风扇置于安全占空比(默认全速)
  * 极性自适应: 本板 PWM 极性为 inversed, 脚本自动取反映射,
    保证"占空比百分比 = 风扇转速百分比"
"""

import argparse
import glob
import logging
import os
import signal
import sys
import time

# ------------------------- 可调参数 -------------------------
PWM_CHIP      = "/sys/class/pwm/pwmchip0"   # PWM0 控制器
PWM_INDEX     = 0                           # 通道号: PWM0_0
PWM_PERIOD_NS = 40_000                      # PWM 周期 40us = 25 kHz
TEMP_MIN      = 35.0                        # °C, 该温度及以下占空比 0%
TEMP_MAX      = 60.0                        # °C, 该温度及以上占空比 100%
TEMP_ON       = 36.5                        # °C, 滞回启动阈值
TEMP_OFF      = 35.0                        # °C, 滞回停转阈值
MIN_DUTY      = 25.0                        # 运行中的最低占空比(%)
KICK_DUTY     = 100.0                       # 起转瞬时占空比(%)
KICK_SECONDS  = 0.6                         # 起转持续时间(秒)
POLL_INTERVAL = 3.0                         # 温度采样周期(秒)
EMA_ALPHA     = 0.35                        # 平滑系数(0~1, 越小越平滑)
FORCE_INVERT  = None                        # 覆盖极性映射: None=按硬件极性自动
                                            # (本板极性 inversed, 自动取反); True/False 强制
FAILSAFE_DUTY = 100.0                       # 退出/异常时的安全占空比(%)
# ------------------------------------------------------------

log = logging.getLogger("pwm-fan")


def clamp(value, lo, hi):
    return max(lo, min(hi, value))


def read_text(path):
    with open(path, "r") as f:
        return f.read().strip()


def write_text(path, value):
    with open(path, "w") as f:
        f.write(str(value))


class PwmFan:
    """PWM 风扇驱动, 封装 sysfs 读写。"""

    def __init__(self, chip=PWM_CHIP, index=PWM_INDEX):
        self.chip = chip
        self.base = os.path.join(chip, "pwm%d" % index)
        self.polarity = "unknown"
        self.inverted = False

    def export(self):
        """导出 PWM 通道(若已导出则跳过)。"""
        if os.path.isdir(self.base):
            return
        write_text(os.path.join(self.chip, "export"), PWM_INDEX)
        for _ in range(100):
            if os.path.isdir(self.base):
                return
            time.sleep(0.02)
        raise RuntimeError("无法导出 PWM 通道: %s" % self.base)

    def setup(self):
        """初始化: 导出通道 -> 设置周期 -> 使能输出。"""
        self.export()
        write_text(os.path.join(self.base, "period"), PWM_PERIOD_NS)
        try:
            self.polarity = read_text(os.path.join(self.base, "polarity"))
        except OSError:
            self.polarity = "unknown"
        # 本板 PWM 极性为 inversed(引脚波形与 duty_cycle 反相):
        # 占空比 0%(停转)需写 duty_cycle=周期, 100%(全速)需写 0。
        self.inverted = (self.polarity == "inversed") if FORCE_INVERT is None \
            else bool(FORCE_INVERT)
        write_text(os.path.join(self.base, "enable"), 1)
        log.info("PWM 就绪: %s 周期 %d ns (%.1f kHz) 极性 %s, 映射%s",
                 self.base, PWM_PERIOD_NS, 1e6 / PWM_PERIOD_NS, self.polarity,
                 "取反(inversed)" if self.inverted else "直通")

    def set_duty(self, percent):
        """设置占空比(0~100%, 指风扇转速百分比), 返回实际写入的 duty_cycle(ns)。"""
        percent = clamp(float(percent), 0.0, 100.0)
        if self.inverted:
            percent = 100.0 - percent
        duty_ns = int(round(PWM_PERIOD_NS * percent / 100.0))
        write_text(os.path.join(self.base, "duty_cycle"), duty_ns)
        return duty_ns

    def get_duty_ns(self):
        return int(read_text(os.path.join(self.base, "duty_cycle")))


def find_temp_sources():
    """自动寻找所有 CPU 温度节点, 取其中最高值(兼顾大小核)。"""
    sources = []
    for zone in sorted(glob.glob("/sys/class/thermal/thermal_zone*")):
        try:
            ztype = read_text(os.path.join(zone, "type"))
        except OSError:
            continue
        if "cpu" in ztype:
            sources.append(os.path.join(zone, "temp"))
    if not sources:
        sources = ["/sys/class/thermal/thermal_zone0/temp"]
    return sources


def read_cpu_temp(sources):
    """读取 CPU 温度(°C), 多个来源取最大值。"""
    temps = []
    for path in sources:
        try:
            temps.append(int(read_text(path)) / 1000.0)
        except (OSError, ValueError):
            continue
    if not temps:
        raise RuntimeError("无法读取 CPU 温度")
    return max(temps)


def install_signal_handlers(fan):
    def _handler(signum, frame):
        log.warning("收到信号 %s, 将风扇置于安全占空比 %.0f%% 后退出",
                    signum, FAILSAFE_DUTY)
        try:
            fan.set_duty(FAILSAFE_DUTY)
        except OSError as e:
            log.error("设置安全占空比失败: %s", e)
        sys.exit(0)

    signal.signal(signal.SIGTERM, _handler)
    signal.signal(signal.SIGINT, _handler)


def control_loop(fan, sources, interval):
    running = False      # 风扇是否处于运行状态(滞回状态机)
    duty = 0.0           # 当前平滑后的占空比
    last_logged = -1     # 上次打印日志的占空比
    read_fails = 0       # 连续读温失败次数

    while True:
        t0 = time.monotonic()
        try:
            temp = read_cpu_temp(sources)
            read_fails = 0
        except RuntimeError as e:
            read_fails += 1
            log.error("读取温度失败(连续 %d 次): %s", read_fails, e)
            if read_fails >= 5:
                log.critical("连续读温失败, 进入安全模式: 风扇 %.0f%%", FAILSAFE_DUTY)
                try:
                    fan.set_duty(FAILSAFE_DUTY)
                except OSError as e2:
                    log.error("写入 PWM 失败: %s", e2)
            time.sleep(max(0.5, interval))
            continue

        # 目标占空比: 35~60°C 线性插值
        raw = clamp((temp - TEMP_MIN) / (TEMP_MAX - TEMP_MIN) * 100.0, 0.0, 100.0)

        # 滞回状态机
        if not running:
            if temp >= TEMP_ON:
                running = True
                fan.set_duty(KICK_DUTY)     # 起转"踢一脚"
                time.sleep(KICK_SECONDS)
                duty = float(KICK_DUTY)
                target = max(raw, MIN_DUTY)
                log.info("风扇启动: 温度 %.1f°C, 目标占空比 %.0f%%", temp, target)
            else:
                target = 0.0
        else:
            if temp <= TEMP_OFF:
                running = False
                target = 0.0
                log.info("风扇停转: 温度 %.1f°C", temp)
            else:
                target = max(raw, MIN_DUTY)

        # EMA 平滑
        duty += EMA_ALPHA * (target - duty)
        out = int(round(duty))
        try:
            fan.set_duty(out)
        except OSError as e:
            log.error("写入 PWM 失败: %s", e)

        if last_logged < 0 or abs(out - last_logged) >= 2:
            log.info("温度 %.1f°C -> 占空比 %d%%", temp, out)
            last_logged = out

        time.sleep(max(0.2, interval - (time.monotonic() - t0)))


def show_status():
    fan = PwmFan()
    try:
        fan.export()
    except RuntimeError as e:
        print("PWM: %s" % e)
        return 1
    for name in ("period", "duty_cycle", "enable", "polarity"):
        try:
            value = read_text(os.path.join(fan.base, name))
        except OSError as e:
            value = "<不可读: %s>" % e
        print("%s = %s" % (name, value))
    try:
        sources = find_temp_sources()
        print("温度来源: %s" % ", ".join(sources))
        print("当前 CPU 温度: %.1f°C" % read_cpu_temp(sources))
    except RuntimeError as e:
        print("温度: %s" % e)
    return 0


def parse_args():
    parser = argparse.ArgumentParser(description="PWM 风扇温控(基于 CPU 温度)")
    parser.add_argument("--test", type=float, metavar="0-100",
                        help="测试模式: 初始化 PWM 后设置为指定占空比并退出")
    parser.add_argument("--temp-file", metavar="PATH",
                        help="调试用: 从普通文件读取温度(内容为毫摄氏度整数)")
    parser.add_argument("--interval", type=float, default=POLL_INTERVAL,
                        help="温度采样周期(秒), 默认 %.1f" % POLL_INTERVAL)
    parser.add_argument("--show", action="store_true",
                        help="仅打印当前 PWM 与温度状态后退出")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="输出调试日志")
    return parser.parse_args()


def main():
    args = parse_args()
    logging.basicConfig(
        stream=sys.stdout,
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    if args.show:
        return show_status()

    fan = PwmFan()
    fan.setup()

    if args.test is not None:
        duty_ns = fan.set_duty(args.test)
        log.info("测试: 占空比 %.1f%% -> duty_cycle=%d ns (周期 %d ns)",
                 args.test, duty_ns, PWM_PERIOD_NS)
        return 0

    sources = [args.temp_file] if args.temp_file else find_temp_sources()
    log.info("温度来源: %s", sources)
    log.info("温控曲线: %.0f°C=0%% ~ %.0f°C=100%%, 滞回启动 %.0f°C/停转 %.0f°C, "
             "最低 %.0f%%, 采样周期 %.1fs", TEMP_MIN, TEMP_MAX, TEMP_ON, TEMP_OFF,
             MIN_DUTY, args.interval)

    install_signal_handlers(fan)
    try:
        control_loop(fan, sources, args.interval)
    except Exception:
        log.exception("发生未处理异常, 进入安全模式")
        try:
            fan.set_duty(FAILSAFE_DUTY)
        except OSError:
            pass
        raise
    return 0


if __name__ == "__main__":
    sys.exit(main())
