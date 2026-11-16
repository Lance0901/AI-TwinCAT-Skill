建立 FB_Axis 用來控制 NC 軸的 PTP、Velocity、Home。

介面規格:
```
instance:MAIN.fbAxis : FB_Axis;軸以 VAR_IN_OUT Axis : AXIS_REF 傳入(MAIN 內接 GVL_Axis.stAxis1)
輸入:bEnable、bReset、bHome、fHomePosition(預設 0)、
      bMoveAbs、fPosition、fVelocity、bMoveVelo、fVeloSet(正負代表方向)、bStop
      (bHome / bMoveAbs / bMoveVelo / bStop 為上升緣觸發)
輸出:bReady(軸已 enable)、bHomed、bBusy、bDone、bError、nErrorId、fActPos、fActVelo
備註:模擬軸沒有原點開關,Home 的作法由 AI 決定,結果要等於 fHomePosition
```

專案在 {{SOLUTION_PATH}},目標是本機 UmRT;做完請自己用 ADS 驗證每個功能,並回報驗證了什麼、結果是什麼。
