require 'open-uri'
include ApiHelper

class GithubController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :verify_github, :except => [:update_deploy_to_master]

  # Fires whenever a CI service finishes.
  def status_hook
    # We're not interested in PR statuses or branches other than deploy
    unless params[:branches].index { |b| b[:name] == "deploy" }
      render text: "Not a commit on deploy. Uninterested." and return
    end

    # Create a new CommitStatus

    if CommitStatus.find_by_commit_sha(params[:sha])
      render text: "Already recorded status for commit", status: 200
      return
    end

    if params[:state] == "pending"
      render text: "We don't record pending statuses", status: 200
      return
    end

    commit_sha = params[:sha]
    status = params[:state]
    commit_message = params[:commit][:commit][:message]
    ci_url = params[:target_url]

    ActionCable.server.broadcast "smokedetector_messages", { commit_status: { status: status, ci_url: ci_url, commit_sha: commit_sha, commit_message: commit_message } }
    CommitStatus.create(:commit_sha => commit_sha, :status => status)

    render text: "OK", status: 200
  end

  # Fires when a wiki page is updated on Charcoal-SE/metasmoke or Charcoal-SE/SmokeDetector
  def gollum_hook
    Travis::Repository.find('Charcoal-SE/charcoal-session.github.io').last_build.restart
  end

  # Fires whenever a PR is opened to check for auto-blacklist and post stats
  def pull_request_hook
    unless request.request_parameters[:action] == "opened"
      render text: "Not a newly-opened PR. Uninterested." and return
    end

    pull_request = params[:pull_request]

    unless pull_request[:user][:login] == "SmokeDetector"
      render text: "Not from SmokeDetector. Uninterested." and return
    end

    text = pull_request[:body]

    response_text = ""

    # Identify blacklist type and use appropriate search

    domains = text.scan(/<!-- METASMOKE-BLACKLIST-WEBSITE (.*?) -->/)[0][0]

    domains.each do |domain|
      num_tps = Post.where("body LIKE '%#{domain}%'").where(:is_tp => true).count
      num_fps = Post.where("body LIKE '%#{domain}%'").where(:is_fp => true).count
      num_naa = Post.where("body LIKE '%#{domain}%'").where(:is_naa => true).count

      response_text += "#{domain} has been seen in #{num_tps} true #{'positive'.pluralize(num_tps)}, #{num_fps} false #{'positive'.pluralize(num_fps)}, and #{num_naa} #{'NAA'.pluralize(num_naa)}.\n\n"
    end

    keywords = text.scan(/<!-- METASMOKE-BLACKLIST-KEYWORD (.*?) -->/)[0][0]

    keywords.each do |keyword|
      num_tps = Post.where("body LIKE '%#{keyword}%'").where(:is_tp => true).count
      num_fps = Post.where("body LIKE '%#{keyword}%'").where(:is_fp => true).count
      num_naa = Post.where("body LIKE '%#{keyword}%'").where(:is_naa => true).count

      response_text += "#{keyword} has been seen in #{num_tps} true #{'positive'.pluralize(num_tps)}, #{num_fps} false #{'positive'.pluralize(num_fps)}, and #{num_naa} #{'NAA'.pluralize(num_naa)}.\n\n"
    end

    usernames = text.scan(/<!-- METASMOKE-BLACKLIST-USERNAME (.*?) -->/)[0][0]

    usernames.each do |username|
      num_tps = Post.where("body LIKE '%#{username}%'").where(:is_tp => true).count
      num_fps = Post.where("body LIKE '%#{username}%'").where(:is_fp => true).count
      num_naa = Post.where("body LIKE '%#{username}%'").where(:is_naa => true).count

      response_text += "#{username} has been seen in #{num_tps} true #{'positive'.pluralize(num_tps)}, #{num_fps} false #{'positive'.pluralize(num_fps)}, and #{num_naa} #{'NAA'.pluralize(num_naa)}.\n\n"
    end

    Octokit.add_comment "Charcoal-SE/SmokeDetector", pull_request[:number], response_text

    render text: response_text, status: 200
  end

  # Fires when a PR is posted for our fake CI service to require reviews on
  def ci_hook
    case request.headers['HTTP_X_GITHUB_EVENT']
      when 'pull_request'
        data = JSON.parse(request.raw_post)
        pull_request = data['pull_request']
        case data['action']
          when 'opened'
            commits = JSON.parse(Net::HTTP.get_response(URI.parse(pull_request['commits_url'])).body)
            commits.each do |commit|
              ApiHelper.authorized_post("https://api.github.com/repos/Charcoal-SE/SmokeDetector/statuses/#{commit['sha']}", {
                :state => "pending",
                :description => "An Approve review is required before pull requests can be merged.",
                :context => "metasmoke/ci"
              })
            end

            render plain: "#{commits.length} commits set to pending."
          when 'synchronize'
            commits = JSON.parse(Net::HTTP.get_response(URI.parse(pull_request['commits_url'])).body)
            commits.each do |commit|
              ApiHelper.authorized_post("https://api.github.com/repos/Charcoal-SE/SmokeDetector/statuses/#{commit['sha']}", {
                  :state => "pending",
                  :description => "An Approve review is required before pull requests can be merged.",
                  :context => "metasmoke/ci"
              })
            end

            render plain: "#{commits.length} commits set to pending."
          else
            render plain: "Not a newly-opened or updated PR; not interested." and return
        end
      when 'pull_request_review'
        data = JSON.parse(request.raw_post)
        pull_request = data['pull_request']
        review = data['review']
        if data['action'] == 'submitted' && review['state'] == 'approved'
          commits = JSON.parse(Net::HTTP.get_response(URI.parse(pull_request['commits_url'])).body)
          commits.each do |commit|
            ApiHelper.authorized_post("https://api.github.com/repos/Charcoal-SE/SmokeDetector/statuses/#{commit['sha']}", {
                :state => "success",
                :description => "PR approved :)",
                :context => "metasmoke/ci"
            })
          end

          render plain: "#{commits.length} commits approved."
        else
          render plain: "Not a submitted Approve review; not interested." and return
        end
      else
        render plain: "Pretty sure we don't subscribe to that event." and return
    end
  end

  # Fires when a new push is made to Charcoal-SE/metasmoke, so we can bust
  # the status/code caches
  def metasmoke_push_hook
    Rails.cache.delete_matched /code_status\/.*##{CurrentCommit}/
  end

  # Fires whenever anything is pushed, so we can automatically update `deploy`
  # to point to master's HEAD
  def update_deploy_to_master
    unless params[:ref] == "refs/heads/master"
      render plain: "Not on master; not interested" and return
    end

    new_sha1 = params[:after]

    # false indicates a not-force-push
    Octokit.update_ref "Charcoal-SE/SmokeDetector", "heads/deploy", new_sha1, false
  end

  private
    def verify_github
      signature = 'sha1=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), AppConfig['github']['secret_token'], request.raw_post)
      render plain: "You're not GitHub!", status: 403 and return unless Rack::Utils.secure_compare(signature, request.env['HTTP_X_HUB_SIGNATURE'])
    end
end
