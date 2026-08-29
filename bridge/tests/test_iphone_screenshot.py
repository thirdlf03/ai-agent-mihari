class TestCapturePathSelection:
    """iOS のバージョンでキャプチャ経路が変わること。

    iOS 17+ で ``com.apple.mobile.screenshotr`` を使うと、RSD のサービス一覧に
    載っていないため ``No such service`` になる(iOS 26.4.1 の実機で確認)。
    DVT の ``...services.screenshot`` を使わなければならない。
    """

    def test_ios_17_and_later_requires_tunneld(self) -> None:
        from device_bridge.commands.screenshot import requires_tunneld

        assert requires_tunneld("17.0") is True
        assert requires_tunneld("26.4.1") is True

    def test_older_ios_does_not_require_tunneld(self) -> None:
        from device_bridge.commands.screenshot import requires_tunneld

        assert requires_tunneld("16.7") is False

    def test_dvt_helper_exists_for_the_modern_path(self) -> None:
        # 経路の取り違えは実機でしか露見しないので、少なくとも入口の存在を固定しておく。
        from device_bridge.commands import screenshot_source

        assert hasattr(screenshot_source, "_capture_via_dvt")
