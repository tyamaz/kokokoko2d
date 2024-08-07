local timer_util = require("kokokoko.timer_util")
local sign = require("kokokoko2d.sign_define")
local M = {}
local ns_id = vim.api.nvim_create_namespace("kokokoko2d_namespace")


--- 対象行が折りたたまれているか否か
--- @param buffer any 対象のバッファ
--- @param line any 対象の行 1 始まり
--- @return unknown
local function is_folded(buffer, line)
  return vim.api.nvim_buf_call(buffer, function()
    return vim.fn.foldclosed(line) ~= -1
  end)
end


local function count_line_without_folded(buffer, from_lnum, to_lnum)
  local updown = from_lnum > to_lnum and -1 or 1
  local cnt = 0

  for i = from_lnum, to_lnum, updown do
    -- 折れて表示されてなかったら
    if not is_folded(buffer, i) then
      cnt = cnt + 1
    end
  end

  return cnt
end



--- 1個分を描画する
--- @param buffer any    対象のバッファ
--- @param character any どの文字を描画するか 1文字
--- @param hlgroup any   対象の文字に対する hlgroup
--- @param pos any       位置 { lnum = 1, cnum = 10 } みたいな 1 開始換算
--- @param speed any     表示している時間(ミリ秒)、この時間後勝手に消去される
--- @param priority any  優先度 デカい値が優先に表示される
function M.render_one(buffer, character, hlgroup, pos, speed, priority)
  -- タイミングによってゼロで来る可能性もあってそれでエラーになることを防ぐ
  if pos.cnum < 1 then
    return
  end

  -- 描画
  local extmark_id = vim.api.nvim_buf_set_extmark(
      buffer,
      ns_id,
      pos.lnum - 1,  -- 行指定 この関数は 0 開始換算なので 1 引く
      0,   -- 横位置調整は virt_text_pos_win_col で行うのでゼロ指定
      {
        virt_text_pos = "overlay",         -- 既存の上に載せて出す
        virt_text_win_col = pos.cnum - 1,  -- 事実上列位置指定 この関数は 0 開始換算なので 1 引く
        virt_text = {{character, hlgroup}},  -- 何出すか
        priority = priority
      })
  -- 描画の直後に時限で消去
  timer_util.setTimeout(
      function()
        -- id 指定で消す
        vim.api.nvim_buf_del_extmark(buffer, ns_id, extmark_id)
      end,
      speed)  -- 消すまでの時間、
end


--- 1マス分描画する
--- @param buffer any     対象のバッファ
--- @param pos any        位置 {lnum = 1, cnum = 2 }
--- @param speed any      描画時間
function M.render(buffer, pos, speed)
  -- どの軌跡のセットを使うか
  local type_name = "default"
  -- 全体表示時間から1コマの表示時間を計算する
  local koma_speed = math.floor(speed / 7)
  for i = 1, 7, 1 do
    local s = sign.get_point_sign(type_name, i)
    M.render_one(
      buffer,
      s.shape,
      s.hlgroup,
      pos,
      koma_speed * i,    -- 優先度が低いコマほど長く、高いコマほど短く描画することでパラパラ漫画にできる
      1000 + 7 - i
    )
  end
end

--- 【no use】
--- 始点と終点を指定してその間を描画する 行ベース
--- @param buffer any
--- @param from_pos any
--- @param to_pos any
--- @param speed any
function M.render_range(buffer, from_pos, to_pos, speed)
  -- 行移動ベースで差分を蓄積することで位置を求める
  -- 折りたたみを無視する
  local dist_l = count_line_without_folded(buffer, from_pos.lnum, to_pos.lnum)

  -- 同一行ならしない
  if dist_l == 0 then
    return
  end

  local dist_c = math.abs(to_pos.cnum - from_pos.cnum)
  -- 1行あたり何列分移動させればよいか(小数)
  local c_step = dist_c / dist_l

  -- 1行に何秒間描画すればよいか
  -- 内部ではこの時間を元に軌跡が全部繋がるように時間を決める
  local line_speed = math.floor(speed / dist_l)   -- 距離は行ベースとする
  if line_speed == 0 then
    line_speed = 1
  end
  -- どっちに進むか
  local updown = from_pos.lnum > to_pos.lnum and -1 or 1
  local lr = from_pos.cnum > to_pos.cnum and -1 or 1

  -- 誤差を少なくするための厳密な列位置の計算
  local pos_c = from_pos.cnum

  local count_folded = 0

  -- 行ベースでループ
  for l = from_pos.lnum, to_pos.lnum, updown do
    -- 最後の行は描画しない
    if l == to_pos.lnum then
      goto continue
    end
    -- 行が折りたたまれて表示されていないなら描画しない
    if is_folded(buffer, l) then
      count_folded = count_folded + 1
      goto continue
    end

    -- 厳密な列位置を実際の列位置に変換
    local c = math.floor(pos_c)
    local order = math.abs(l - from_pos.lnum) - count_folded  -- 折りたたみを飛ばしている分実際はもっと近い

    timer_util.setTimeout(
        function()
          M.render(buffer, {lnum = l, cnum = c}, speed)
        end,
        line_speed * order)
    -- ↑ 終点にに接近するほど描画するまでが遅い
    -- つまり、始点から終点に進んでいるように見える

    -- 厳密に位置を積算する
    -- c_step に折りたたみが無い分が織り込み済み
    pos_c = pos_c + (lr * c_step)
    ::continue::
  end

end

--- 【no use】
--- 始点と終点を指定してその間を描画する 列ベース
--- 列の移動をベースに軌跡を描画する
--- 行の移動に対して列の移動が多い場合に使うとよいかも
--- 上下に長い距離を移動する場合はこちらのほうが見た目が良好
--- @param buffer any
--- @param from_pos any
--- @param to_pos any
--- @param speed any
function M.render_range_based_column(buffer, from_pos, to_pos, speed)
  -- 行移動ベースで差分を蓄積することで位置を求める
  -- 折りたたみを無視する
  local dist_l = count_line_without_folded(buffer, from_pos.lnum, to_pos.lnum)

  -- 同一行ならしない この場合は同一行でも行う

  local dist_c = math.abs(to_pos.cnum - from_pos.cnum)

  if dist_c < 1 then
    -- 差無しでも動作させるために1を入れておく
    dist_c = 1
  end
  -- 1列あたり何行分移動させればよいか(小数)
  local l_step = dist_l / dist_c

  -- 1列に何秒間描画すればよいか
  -- 内部ではこの時間を元に軌跡が全部繋がるように時間を決める
  local column_speed = math.floor(speed / dist_c)   -- 距離は列ベースとする
  if column_speed == 0 then
    column_speed = 1
  end
  -- どっちに進むか
  local updown = from_pos.lnum > to_pos.lnum and -1 or 1
  local lr = from_pos.cnum > to_pos.cnum and -1 or 1

  -- 誤差を少なくするための厳密な行位置の計算
  -- 整数計算だけでやる方法よりも分かりやすさ重視
  local pos_l = from_pos.lnum

  local count_folded = 0

  -- 行ベースでループ
  for c = from_pos.cnum, to_pos.cnum, lr do
    -- 最後は描画しない
    if c == to_pos.cnum then
       goto continue
    end
    local l = 0
    if updown == -1 then
      -- 上方向に向かっているなら切り下げる(行きすぎないように下(大きい数字)に戻す)
      l = math.ceil(pos_l)
    elseif updown == 1 then
      -- 下方向に向かっているなら切り上げる(行きすぎないように上(小さい数字)に戻す)
      l = math.floor(pos_l)
    end
    -- 行が折りたたまれて表示されていないなら描画しない
    if is_folded(buffer, l) then
      count_folded = count_folded + 1
      goto continue
    end

    local order = math.abs(c - from_pos.cnum) - count_folded  -- 折りたたみを飛ばしている分実際はもっと近い

    timer_util.setTimeout(
        function()
          M.render(buffer, {lnum = l, cnum = c}, speed)
        end,
        column_speed * order)
    -- ↑ 終点にに接近するほど描画するまでが遅い
    -- つまり、始点から終点に進んでいるように見える

    -- 厳密に位置を積算する
    -- c_step に折りたたみが無い分が織り込み済み
    pos_l = pos_l + (updown * l_step)
    ::continue::
  end
end


--- 始点と終点を指定してその間を描画する 縦横距離ベース
--- 縦横の距離ベースに軌跡を描画する。飛ばされる部分無くビッチリ描画される
--- @param buffer any
--- @param from_pos any {lnum = 12, cnum = 34}  みたいな。行列共に 1 スタート換算
--- @param to_pos any
--- @param speed any
function M.render_range_based_dist(buffer, from_pos, to_pos, speed)
  -- 行移動ベースで差分を蓄積することで位置を求める
  -- 折りたたみを無視する
  local dist_l = count_line_without_folded(buffer, from_pos.lnum, to_pos.lnum)
  local dist_c = math.abs(to_pos.cnum - from_pos.cnum)


  -- 1行当たりの1列の描画量(小数)
  -- Lua はゼロ除算でエラーでなく結果無限に設定される
  local step_c = 0
  if dist_l < 1 then
    step_c = 300.0  -- 1行描画するには十分な量
  else
    step_c = dist_c / dist_l
  end

  if dist_c < 1 then
    -- 差無しでも動作させるために1を入れておく
    dist_c = 1
  end

  -- 1エリアに何秒間描画すればよいか
  -- 内部ではこの時間を元に軌跡が全部繋がるように時間を決める
  local render_speed = math.floor(speed / (dist_l + (dist_c / 2)))
  if render_speed < 1 then
    render_speed  = 1
  end
  -- どっちに進むか
  local updown = 0  -- 進まないならゼロ
  if from_pos.lnum > to_pos.lnum then
    updown = -1  -- from がでかいから下から上に向かう
  elseif from_pos.lnum < to_pos.lnum then
    updown = 1   -- from が小さいから上から下に向かう
  end
  local lr = 0  -- 進まないならゼロ
  if from_pos.cnum > to_pos.cnum then
    lr = -1 -- from がデカいから右から左に向かう
  elseif  from_pos.cnum < to_pos.cnum then
    lr = 1  -- from が小さいから左から右に向かう
  end


  -- 誤差を少なくするための厳密な列描画位置の計算
  -- 整数計算だけでやる方法よりも分かりやすさ重視(縦横比の整数倍の差で切り上げるか下げるか判定より)
  local pos_c = from_pos.cnum

  -- 折れている行数カウント(描画しない)
  local count_folded = 0
  -- 何個描画したかカウント
  local count_render = 0



  -- 行ベースでループ 基本行 → 列 で描画していく
  -- 進まない場合が1ループだけする updown 0 だと無限ループになるので適当な値を入れて1周だけするようにする
  for l = from_pos.lnum, to_pos.lnum, (updown == 0 and 100 or updown) do
    -- 行が折りたたまれて表示されていないなら描画しない
    if is_folded(buffer, l) then
      count_folded = count_folded + 1
      goto continue
    end

    -- 複数行あるやつの最後の1行だけ動作させない
    -- つまり単独1周は処理する
    if (from_pos.lnum ~= to_pos.lnum) and (l == to_pos.lnum) then
      goto continue
    end

    local from_pos_c = 0
    local to_pos_c = 0
    if lr == -1 then
      -- 左方向に向かっているなら切り上げる(行きすぎないように右(大きい数字)に戻す)
      from_pos_c = math.ceil(pos_c)
      to_pos_c = math.ceil(pos_c + (lr * step_c))
    elseif lr == 1 then
      -- 右方向に向かっているなら切り下げる(行きすぎないように左(小さい数字)に戻す)
      from_pos_c = math.floor(pos_c)
      to_pos_c = math.floor(pos_c + (lr * step_c))
    elseif lr == 0 then
      -- 動かない場合はその場1周のみ
      from_pos_c = math.floor(pos_c)
      to_pos_c = math.floor(pos_c)
    end

    -- 列ベースでループ
    -- そもそも横方向は狭いし、マーカーは広いし、描画も早いので間引く
    -- 動かない場合でも1周だけ描画はする
    for c = from_pos_c, to_pos_c, (lr == 0 and 100 or lr) do
      -- 1周のみでない且つ奇数行のみ描画する
      if (from_pos_c ~= to_pos_c) and (c % 2 == 1) then
        -- goto skiprender
      end
      timer_util.setTimeout(
          function()
            M.render(buffer, {lnum = l, cnum = c}, speed)
          end,
          render_speed * count_render)
      -- ↑ 終点にに接近するほど描画するまでが遅い
      -- つまり、始点から終点に進んでいるように見える

      ::skiprender::
      count_render = count_render + 1
    end
    -- 厳密に位置を積算する
    pos_c = pos_c + (lr * step_c)
    ::continue::
  end
end


return M

