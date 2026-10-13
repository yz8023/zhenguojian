package core

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// VIP 探询的整体超时：探询失败只影响 VIP 标记，不能拖慢详情加载。
const huangdouVIPProbeTimeout = 6 * time.Second

func huangdouVIPFlag(item map[string]any) *bool {
	var known *bool
	for _, key := range []string{"is_vip", "isVip"} {
		value := strings.ToLower(mapString(item, key))
		if value == "true" || value == "1" || value == "y" {
			result := true
			return &result
		}
		if value == "false" || value == "0" || value == "n" {
			result := false
			known = &result
		}
	}
	switch strings.ToLower(mapString(item, "pay_type")) {
	case "vip":
		result := true
		return &result
	case "free":
		result := false
		known = &result
	}
	for _, episode := range huangdouVIPEpisodes(item) {
		if episode > 0 {
			result := true
			return &result
		}
	}
	for _, episode := range huangdouList(item["episodes"]) {
		if strings.EqualFold(mapString(episode, "type"), "vip") {
			result := true
			return &result
		}
	}
	return known
}

func huangdouVIPEpisodes(item map[string]any) []int {
	var result []int
	if values, ok := item["vip_episodes"].([]any); ok {
		for _, value := range values {
			if index, err := strconv.Atoi(fmt.Sprint(value)); err == nil && index > 0 && index <= 10000 {
				result = append(result, index)
			}
		}
	}
	return result
}

func huangdouEpisodeVIP(detail, episode map[string]any, seq int) bool {
	switch strings.ToLower(mapString(episode, "type")) {
	case "vip":
		return true
	case "free":
		return false
	}
	for _, index := range huangdouVIPEpisodes(detail) {
		if index == seq {
			return true
		}
	}
	if flag := huangdouVIPFlag(episode); flag != nil {
		return *flag
	}
	if strings.EqualFold(mapString(detail, "pay_type"), "vip") {
		free, err := strconv.Atoi(mapString(detail, "free_episodes"))
		return err == nil && free >= 0 && seq > free
	}
	return false
}

// 详情接口是否已经能确定 VIP 边界。
//
// 能确定时就不必再探询播放接口（省请求）。
func huangdouVIPKnown(detail map[string]any) bool {
	if strings.EqualFold(mapString(detail, "pay_type"), "vip") {
		return true
	}
	if len(huangdouVIPEpisodes(detail)) > 0 {
		return true
	}
	for _, key := range []string{"is_vip", "isVip"} {
		switch strings.ToLower(mapString(detail, key)) {
		case "true", "1", "y", "false", "0", "n":
			return true
		}
	}
	for _, episode := range huangdouList(detail["episodes"]) {
		if strings.EqualFold(mapString(episode, "type"), "vip") {
			return true
		}
	}
	return false
}

// 探询播放接口，判断某一集是否需要 VIP。
//
// 背景：黄豆的 VIP 信息在**播放接口**才准确返回，剧详情接口常常只给出
// 试看集（第 1、2 集），因此列表阶段识别不出 VIP 剧。
//
// 返回值：
//   - true  = 该集需要 VIP（接口明确拒绝或只给试看）
//   - false = 该集可正常播放
//
// 关键边界：**探询失败一律当作"不需要 VIP"**，避免把能播的集误标为 VIP。
func huangdouProbeEpisodeVIP(ctx context.Context, client *huangdouAPIClient, sourceID string, seq int) bool {
	if seq <= 0 {
		return false
	}
	var decoded any
	if err := client.call(ctx, "/drama/play", map[string]any{"id": sourceID, "seq": strconv.Itoa(seq)}, &decoded); err != nil {
		var failure *huangdouAPIError
		if errors.As(err, &failure) {
			switch failure.code {
			case "813004", "813005", "813006", "813103", "vip":
				return true
			case "preview":
				// 只给试看 ⇒ 正片需要 VIP。
				return true
			}
		}
		return false
	}
	data := huangdouDataMap(decoded)
	media := firstNonEmpty(mapString(data, "m3u8"), mapString(data, "url"), mapString(data, "play_url"), mapString(data, "playUrl"))
	if huangdouPreviewOnly(data, media, client.host) {
		return true
	}
	if strings.EqualFold(mapString(data, "is_vip", "isVip"), "true") ||
		strings.EqualFold(mapString(data, "need_vip", "needVip"), "true") ||
		strings.EqualFold(mapString(data, "is_pay"), "true") {
		return true
	}
	return false
}

// 探询 VIP 起始集号。
//
// 做法：从前往后找到第一个"需要 VIP"的集，返回它的集号。
// 找不到（整部剧都能免费播）返回 0。
//
// 限制：最多探询 maxProbes 集，避免集数很多的剧发太多请求。
// 为避免影响详情页加载速度，探询设有整体超时。
func huangdouProbeVIPStart(ctx context.Context, client *huangdouAPIClient, sourceID string, total int) int {
	const maxProbes = 6
	if total <= 0 {
		return 0
	}
	limit := total
	if limit > maxProbes {
		limit = maxProbes
	}
	for seq := 1; seq <= limit; seq++ {
		if ctx.Err() != nil {
			return 0
		}
		if huangdouProbeEpisodeVIP(ctx, client, sourceID, seq) {
			return seq
		}
	}
	return 0
}
