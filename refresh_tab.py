#!/usr/bin/env python3
"""refresh_tab.py — 刷新 Firefox 第一个标签页 (使用 python-xlib XTEST 扩展)

用法:
    python3 refresh_tab.py :99        # 指定 display
    python3 refresh_tab.py            # 默认 :99
"""
import sys
import time
from Xlib import X, display, XK
from Xlib.ext import xtest


def find_firefox_window(d):
    """递归查找 Firefox 窗口"""
    root = d.screen().root

    def search(win):
        try:
            cls = win.get_wm_class()
            if cls and cls[0] and cls[1] and 'firefox' in (cls[0].lower(), cls[1].lower()):
                return win
        except Exception:
            pass
        try:
            for child in win.query_tree().children:
                result = search(child)
                if result:
                    return result
        except Exception:
            pass
        return None

    return search(root)


def send_key(d, keycode):
    """发送单个按键 (按下 + 释放)"""
    xtest.fake_input(d, X.KeyPress, keycode)
    xtest.fake_input(d, X.KeyRelease, keycode)
    d.flush()


def send_key_combo(d, modifier_keycode, key_keycode):
    """发送组合键 (如 Ctrl+1)"""
    xtest.fake_input(d, X.KeyPress, modifier_keycode)
    xtest.fake_input(d, X.KeyPress, key_keycode)
    xtest.fake_input(d, X.KeyRelease, key_keycode)
    xtest.fake_input(d, X.KeyRelease, modifier_keycode)
    d.flush()


def main():
    display_name = sys.argv[1] if len(sys.argv) > 1 else ':99'

    try:
        d = display.Display(display_name)
    except Exception as e:
        print(f"无法连接到 display {display_name}: {e}", file=sys.stderr)
        sys.exit(1)

    # 查找并激活 Firefox 窗口
    win = find_firefox_window(d)
    if win:
        try:
            win.configure(stack_mode=X.AboveStack)
            win.set_input_focus(X.RevertToParent, X.CurrentTime)
            d.flush()
        except Exception:
            pass
        time.sleep(0.5)

    # Ctrl+1: 切换到第一个标签页
    ctrl_keycode = d.keysym_to_keycode(XK.XK_Control_L)
    one_keycode = d.keysym_to_keycode(XK.XK_1)
    if ctrl_keycode and one_keycode:
        send_key_combo(d, ctrl_keycode, one_keycode)
        time.sleep(1)

    # F5: 刷新页面
    f5_keycode = d.keysym_to_keycode(XK.XK_F5)
    if f5_keycode:
        send_key(d, f5_keycode)

    d.close()
    print("已刷新第一个标签页")


if __name__ == '__main__':
    main()
