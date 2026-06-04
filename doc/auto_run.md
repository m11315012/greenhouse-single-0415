使用方式

# rehost 一個 firmware
./auto_run.sh --brand dlink --firmware DIR-868L.zip

# rehost 後自動跑 routersploit（約 4 小時）
./auto_run.sh --brand dlink --firmware DIR-868L.zip --routersploit

# 啟動已經 rehost 好的 firmware
./auto_run.sh --run-firmware ./results/<sha256>

# 先 rebuild image 再 rehost
./auto_run.sh --build --brand dlink --firmware DIR-868L.zip

主要設計決策：用 docker run -d ... sleep infinity 讓 container 在背景保持存活，再用 docker exec 逐步執行各個步驟，最後用 trap EXIT 確保 container 一定會被清理掉，即使中途發生錯誤。

https://zenodo.org/records/8217895?preview_file=greenhouse-rehosted.csv


# 帶 FirmAE 優先
./auto_run.sh --brand dlink --firmware DIR-868L.zip --rehost-first