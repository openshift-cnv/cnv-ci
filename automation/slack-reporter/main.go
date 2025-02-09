package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/slack-go/slack"
)

var versions = []string{"4.17", "4.18", "4.19"}

const baseProwURL = "https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/logs/periodic-ci-openshift-release-master-cnv-nightly-%s-e2e-azure-deploy-cnv/"
const finishedURL = baseProwURL + "%s/finished.json"
const jobURLTemplate = baseProwURL + "%s/prowjob.json"

type FinishedJSON struct {
	Passed    bool  `json:"passed"`
	Timestamp int64 `json:"timestamp"`
}

func fetchContent(url string) (string, error) {
	resp, err := http.Get(url)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}

	return strings.TrimSpace(string(body)), nil
}

func checkJobStatus(version string) ([]slack.Block, error) {
	latestBuildURL := fmt.Sprintf(baseProwURL+"latest-build.txt", version)
	latestBuild, err := fetchContent(latestBuildURL)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch latest build for %s: %v", version, err)
	}

	finishedURL := fmt.Sprintf(finishedURL, version, latestBuild)
	finishedData, err := fetchContent(finishedURL)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch finished.json for %s: %v", version, err)
	}

	var result FinishedJSON
	if err := json.Unmarshal([]byte(finishedData), &result); err != nil {
		return nil, fmt.Errorf("failed to parse finished.json for %s: %v", version, err)
	}
	finishedTime := time.Unix(result.Timestamp, 0).UTC()

	jobUrl, err := getJobUrl(latestBuild, version)
	if err != nil {
		return nil, fmt.Errorf("failed to get job url for %s: %v", version, err)
	}

	if !result.Passed {
		blocks := []slack.Block{
			slack.NewRichTextBlock(fmt.Sprintf("result-%s", version), slack.NewRichTextSection(
				slack.NewRichTextSectionEmojiElement("failed", 3, nil),
				slack.NewRichTextSectionTextElement(" ", nil),
				slack.NewRichTextSectionTextElement(fmt.Sprintf("CNV informing job of %s has ", version), nil),
				slack.NewRichTextSectionLinkElement(jobUrl, "failed", &slack.RichTextSectionTextStyle{Bold: true}),
				slack.NewRichTextSectionTextElement(". Job finished at: ", nil),
				slack.NewRichTextSectionDateElement(finishedTime.UTC().Unix(), "{date_short}, {time}", nil, nil),
			)),
		}
		return blocks, nil
	}

	return nil, nil
}

func sendSlackMessage(client *slack.Client, blocks []slack.Block) error {
	slackChannelID, ok := os.LookupEnv("HCO_CHANNEL_ID")
	if !ok {
		return fmt.Errorf("environment variable HCO_CHANNEL_ID not set")
	}
	_, _, err := client.PostMessage(slackChannelID, slack.MsgOptionBlocks(blocks...))
	return err
}

func generateMentionBlock() slack.Block {
	groupId, ok := os.LookupEnv("HCO_GROUP_ID")
	if !ok {
		fmt.Fprintln(os.Stderr, "HCO_GROUP_ID environment variable not set")
		os.Exit(1)
	}
	return slack.NewRichTextBlock("mention", slack.NewRichTextSection(
		slack.NewRichTextSectionTextElement("cc: ", nil),
		slack.NewRichTextSectionUserGroupElement(groupId),
	))
}

func getJobUrl(latestBuild, version string) (string, error) {
	req, err := http.NewRequest(http.MethodGet, fmt.Sprintf(jobURLTemplate, version, latestBuild), nil)
	if err != nil {
		return "", err
	}

	jobResp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}

	defer jobResp.Body.Close()

	job := struct {
		Status struct {
			URL string `json:"url,omitempty"`
		} `json:"status"`
	}{}
	dec := json.NewDecoder(jobResp.Body)
	err = dec.Decode(&job)
	if err != nil {
		return "", err
	}
	return job.Status.URL, nil
}

func main() {
	slackToken := os.Getenv("HCO_REPORTER_SLACK_TOKEN")
	if slackToken == "" {
		log.Fatal("HCO_REPORTER_SLACK_TOKEN environment variable is required")
	}

	slackClient := slack.New(slackToken)

	var failedBlocks []slack.Block

	for _, version := range versions {
		block, err := checkJobStatus(version)
		if err != nil {
			log.Println(err)
			continue
		}

		if block != nil {
			failedBlocks = append(failedBlocks, block...)
		}
	}

	// If any job failed, send a single Slack message with all failures
	if len(failedBlocks) > 0 {
		failedBlocks = append(failedBlocks, generateMentionBlock())
		if err := sendSlackMessage(slackClient, failedBlocks); err != nil {
			log.Printf("Failed to send Slack message: %v", err)
		} else {
			log.Printf("Successfully sent Slack message")
		}
	} else {
		log.Printf("All jobs passed, no need to send any message.")
	}
}
