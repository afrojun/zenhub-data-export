require "dotenv"
require "httparty"
require "optparse"
require "oj"
require "octokit"
require "dry-initializer"

Dotenv.load(".env", ".env.local")

module ZenhubDataExport
  class Exporter
    extend Dry::Initializer

    option :owner
    option :repos
    option :pipelines

    CSV_HEADERS = [
      "Issue Type", "Summary", "Date Created", "Assignee", "Reporter",
      "Description", "Estimate", "GitHub URL", "Labels", "Labels", "Labels", "Priority"
    ].freeze

    def export
      github.repositories.each do |repo|
        board = zenhub.board(repo.id)
        issues = github.issues(repo.name)

        puts "Repo: #{repo.name}"
        board["pipelines"].map do |pipeline|
          next unless pipelines.include?(pipeline["name"])
          puts "Pipeline: #{pipeline["name"]}"

          pipeline_issues = pipeline["issues"].map do |zh_issue|
            issues[zh_issue["issue_number"]].tap do |gh_issue|
              gh_issue&.update_zenhub_data(
                is_epic: zh_issue["is_epic"],
                position: zh_issue["position"],
                estimate: zh_issue.fetch("estimate", {})["value"]
              )
            end
          end.compact

          safe_pipeline_name = pipeline["name"].gsub(/^.*(\\|\/)/, "")
          priority = safe_pipeline_name == "Waiting" ? "Low" : "Medium"

          CSV.open("#{repo.name}_#{safe_pipeline_name}.csv", "wb") do |csv|
            csv << CSV_HEADERS
            pipeline_issues.each do |issue|
              csv << issue.jira_export_columns + [priority]
            end
          end
        end
      end
    end

    def github
      @github ||= ZenhubDataExport::GitHub.new(owner: owner, repos: repos)
    end

    def zenhub
      @zenhub ||= ZenhubDataExport::ZenHub.new
    end
  end

  class ZenHub
    ENDPOINT = "https://api.zenhub.io"
    API_TOKEN = ENV.fetch("ZENHUB_API_TOKEN")

    def board(repo_id)
      response = HTTParty.get(
        "#{ENDPOINT}/p1/repositories/#{repo_id}/board",
        headers: { "X-Authentication-Token" => API_TOKEN }
      )

      Oj.load(response.body)
    end
  end

  class GitHub
    extend Dry::Initializer

    ENDPOINT = "https://api.github.com"
    API_TOKEN = ENV.fetch("GITHUB_API_TOKEN")

    option :owner
    option :repos

    def repositories
      repos.map { |repo| repository(repo) }
    end

    def repository(repo)
      Repository.new(client.repository("#{owner}/#{repo}"))
    end

    def issues(repo)
      client
        .list_issues("#{owner}/#{repo}")
        .each_with_object(Hash.new) { |issue, hash| hash[issue[:number]] = Issue.new(issue) }
    end

    private

    def client
      @client ||= ::Octokit::Client.new(access_token: API_TOKEN, auto_paginate: true)
    end

    class Repository
      extend Dry::Initializer

      option :id
      option :name
      option :full_name
    end

    class Issue
      extend Dry::Initializer

      option :id
      option :html_url
      option :number
      option :title
      option :body
      option :state
      option :created_at
      option :closed_at
      option :labels, proc { |lab| lab&.map { |l| l[:name] } }
      option :user, proc { |u| u&.fetch(:login, nil) }
      option :assignee, proc { |u| u&.fetch(:login, nil) }
      option :estimate, default: -> { nil }
      option :is_epic, default: -> { false }
      option :position, default: -> { 0 }

      def update_zenhub_data(position:, is_epic:, estimate: nil)
        @position = position
        @is_epic = is_epic
        @estimate = estimate
      end

      def jira_export_columns
        [
          issue_type,
          title,
          created_at,
          assignee,
          user,
          body,
          estimate,
          html_url
        ] + padded_labels
      end

      def issue_type
        bug? ? "Bug" : (is_epic ? "Epic" : "New Feature")
      end

      def bug?
        labels.map(&:downcase).include?("bug")
      end

      # Select up to 3 labels and remove 'bug' labels
      def padded_labels
        @labels ||= []
        Array.new(3).zip(@labels).map do |label|
          clean_label = "#{label.last&.gsub(" ", "_")}"
          clean_label.downcase == 'bug' ? '' : clean_label
        end
      end
    end
  end
end

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: zenhub_data_export.rb [options]"

  opts.on("-o", "--owner OWNER", String, "Name of the Repo owner") do |owner|
    options[:owner] = owner
  end

  opts.on("-r", "--repos app1,app2,app3", Array, "List of repository names") do |repos|
    options[:repos] = repos
  end

  opts.on("-p", "--pipelines todo,done", Array, "List of ZenHub Pipelines to query") do |pipelines|
    options[:pipelines] = pipelines
  end

  opts.on("-h", "--help", "Prints this help") do
    puts opts
    exit
  end
end.parse!

ZenhubDataExport::Exporter.new(options).export