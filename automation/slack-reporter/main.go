package main

import (
	"encoding/json"
	"fmt"
	"golang.org/x/net/html"
	"io"
	"log"
	"net/http"
	"os"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/slack-go/slack"
)

var versions = []string{"4.16", "4.17", "4.18", "4.19", "4.20"}

const prowHostname = "https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com"
const baseProwURL = prowHostname + "/gcs/test-platform-results/logs/periodic-ci-openshift-release-master-cnv-nightly-%s-deploy-azure-kubevirt-ovn/"
const finishedURL = baseProwURL + "%s/finished.json"
const jobURLTemplate = baseProwURL + "%s/prowjob.json"
const jobHistoryPageTemplate = "https://prow.ci.openshift.org/job-history/gs/test-platform-results/logs/periodic-ci-openshift-release-master-cnv-nightly-%s-deploy-azure-kubevirt-ovn"

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
		return nil, fmt.Errorf("%s latest job is still running", version)
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

func extractJobs(n *html.Node) []string {
	var links []string
	if n.Type == html.ElementNode && n.Data == "a" {
		for _, attr := range n.Attr {
			if attr.Key == "href" && strings.Contains(attr.Val, "/gcs/test-platform-results/logs/") &&
				!strings.Contains(attr.Val, "latest-build") {
				links = append(links, attr.Val)
			}
		}
	}
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		links = append(links, extractJobs(c)...)
	}

	return links
}

func getLastResults(hrefs []string) ([]FinishedJSON, error) {
	finishedSlice := []FinishedJSON{}
	for _, href := range hrefs {
		resp, err := http.Get(prowHostname + href + "/finished.json")
		if err != nil {
			return nil, err
		}
		defer resp.Body.Close()
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			return nil, err
		}
		finishedJsonStr := strings.TrimSpace(string(body))
		finished := FinishedJSON{}
		if err := json.Unmarshal([]byte(finishedJsonStr), &finished); err != nil {
			fmt.Printf("finished.json for %s has not been found.\n", href)
			continue
		}
		if finished.Passed {
			finishedSlice = append(finishedSlice, finished)
			fmt.Printf("%s job has passed. Adding it to list.\n", href)
		} else {
			fmt.Printf("%s job has failed.\n", href)
			break
		}
	}
	return finishedSlice, nil
}

func getLastBuildsforVersion(version string) []FinishedJSON {
	lastBuildsURL := fmt.Sprintf(baseProwURL, version)
	lastBuildsHtmlResp, err := http.Get(lastBuildsURL)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to fetch last builds for version %s: %v\n", version, err)
		return []FinishedJSON{}
	}
	lastBuildsHtmlDoc, err := html.Parse(lastBuildsHtmlResp.Body)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to parse last builds for version %s: %v\n", version, err)
	}
	hrefs := extractJobs(lastBuildsHtmlDoc)
	sort.Sort(sort.Reverse(sort.StringSlice(hrefs)))
	builds, err := getLastResults(hrefs)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to fetch last builds for version %s: %v\n", version, err)
	}
	return builds
}

func checkSuccessfulLast7jobs() bool {
	var consecutiveSuccessfulBuilds []int
	for _, version := range versions {
		builds := getLastBuildsforVersion(version)
		consecutiveSuccessfulBuilds = append(consecutiveSuccessfulBuilds, len(builds))
	}
	minPassLength := slices.Min(consecutiveSuccessfulBuilds)
	if minPassLength%7 == 0 && minPassLength > 0 {
		return true
	}
	return false
}

func sendSlackMessageSuccess(client *slack.Client) error {
	listElements := []slack.RichTextElement{}
	for _, version := range versions {
		linkElement := slack.NewRichTextSectionLinkElement(fmt.Sprintf(jobHistoryPageTemplate, version), version, &slack.RichTextSectionTextStyle{Bold: true})
		section := slack.NewRichTextSection(linkElement)
		listElements = append(listElements, section)
	}
	richTextList := slack.NewRichTextList(slack.RTEListBullet, 0, listElements...)
	listBlock := slack.NewRichTextBlock("keepalive_block", richTextList)
	message := []slack.Block{
		slack.NewRichTextBlock(fmt.Sprintf("keepalive-message"), slack.NewRichTextSection(
			slack.NewRichTextSectionEmojiElement("solid-success", 2, nil),
			slack.NewRichTextSectionEmojiElement("tada", 2, nil),
			slack.NewRichTextSectionTextElement(" All CNV informing jobs ran in the last 7 days have passed:", nil),
		)),
		listBlock,
	}

	err := sendSlackMessage(client, message)
	if err != nil {
		return err
	}

	return nil
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
			fmt.Println(err)
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
			fmt.Printf("Failed to send Slack message: %v\n", err)
		} else {
			fmt.Println("Successfully sent Slack message")
		}
	} else {
		fmt.Println("All jobs passed, checking for keepalive message.")
		success := checkSuccessfulLast7jobs()
		if success {
			if err := sendSlackMessageSuccess(slackClient); err != nil {
				fmt.Printf("Failed to send Slack message: %v\n", err)
			}
		} else {
			fmt.Println("Condition for sending a keepalive message is not satisfied.")
		}
	}
}
