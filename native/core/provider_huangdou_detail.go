package core

import (
	"context"
	"errors"
	"strings"
	"time"
)

type huangdouDetailEntry struct {
	row       map[string]any
	expiresAt time.Time
}

type huangdouDetailCall struct {
	done chan struct{}
	row  map[string]any
	err  error
}

// huangdouVIPProbe 记录一次播放接口探询的结论。
//
// 详情接口对「试看剧」不带 VIP 标记，只有探询后几集才能确定整部剧
// 是否含 VIP。探询发生在生成分集时，而 Drama 的 VIP 由另一条路径生成，
// 因此需要把结论暂存下来供两边共用。
type huangdouVIPProbe struct {
	hasVIP    bool
	expiresAt time.Time
}

// huangdouVIPProbeTTL 探询结论的缓存时长。
// 探询本身要发多次请求，同一部剧短时间内重复进入详情不应重复探询。
const huangdouVIPProbeTTL = 10 * time.Minute

func (d *Downloader) rememberHuangdouVIPProbe(sourceID string, hasVIP bool) {
	d.providerMu.Lock()
	defer d.providerMu.Unlock()
	if d.huangdouVIPProbes == nil {
		d.huangdouVIPProbes = make(map[string]huangdouVIPProbe)
	}
	d.huangdouVIPProbes[sourceID] = huangdouVIPProbe{
		hasVIP:    hasVIP,
		expiresAt: time.Now().Add(huangdouVIPProbeTTL),
	}
}

// huangdouVIPProbeResult 返回该剧是否已探询过、以及探询结论。
// known 为 false 表示还没有可信结论，调用方应保持“未知”。
func (d *Downloader) huangdouVIPProbeResult(sourceID string) (known bool, hasVIP bool) {
	d.providerMu.Lock()
	defer d.providerMu.Unlock()
	probe, found := d.huangdouVIPProbes[sourceID]
	if !found || time.Now().After(probe.expiresAt) {
		return false, false
	}
	return true, probe.hasVIP
}

func (d *Downloader) huangdouDetail(ctx context.Context, id string) (map[string]any, error) {
	if !rankingSourceID.MatchString(id) {
		return nil, errors.New("无效的黄豆剧集 ID")
	}
	d.providerMu.Lock()
	if cached, found := d.huangdouDetails[id]; found && time.Now().Before(cached.expiresAt) {
		d.providerMu.Unlock()
		return cached.row, nil
	}
	if pending := d.huangdouDetailPending[id]; pending != nil {
		d.providerMu.Unlock()
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-pending.done:
			if (errors.Is(pending.err, context.Canceled) || errors.Is(pending.err, context.DeadlineExceeded)) && ctx.Err() == nil {
				return d.huangdouDetail(ctx, id)
			}
			return pending.row, pending.err
		}
	}
	if d.huangdouDetailPending == nil {
		d.huangdouDetailPending = make(map[string]*huangdouDetailCall)
	}
	call := &huangdouDetailCall{done: make(chan struct{})}
	d.huangdouDetailPending[id] = call
	d.providerMu.Unlock()
	var decoded any
	err := newHuangdouAPIClient(d).call(ctx, "/drama/detail", map[string]any{"id": id}, &decoded)
	row := huangdouDataMap(decoded)
	if err == nil && strings.TrimPrefix(mapString(row, "id", "drama_id"), "rp_") != id {
		row = nil
		err = errors.New("黄豆详情返回了其他剧集")
	}
	d.providerMu.Lock()
	if err == nil {
		if d.huangdouDetails == nil || len(d.huangdouDetails) >= 128 {
			d.huangdouDetails = make(map[string]huangdouDetailEntry)
		}
		d.huangdouDetails[id] = huangdouDetailEntry{row: row, expiresAt: time.Now().Add(dramaRefreshRetryDelay)}
	}
	call.row, call.err = row, err
	delete(d.huangdouDetailPending, id)
	close(call.done)
	d.providerMu.Unlock()
	return row, err
}
