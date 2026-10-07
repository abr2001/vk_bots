# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../bots/unu_autoapprove'

# Фейковый клиент UNU: отдаёт подготовленные задачи/отчёты, записывает аппрувы.
class FakeUnu
  attr_reader :approved
  attr_accessor :tasks, :reports

  def initialize
    @approved = []
    @tasks = []
    @reports = []
  end

  def get_tasks(status: nil, task_id: nil, **_opts)
    list = @tasks
    list = list.select { |t| t['status'] == status } if status
    if task_id
      ids = Array(task_id).map(&:to_i)
      list = list.select { |t| ids.include?(t['id']) }
    end
    { 'tasks' => list }
  end

  def get_reports(task_id:, **_opts)
    ids = Array(task_id).map(&:to_i)
    { 'reports' => @reports.select { |r| ids.include?(r['task_id']) } }
  end

  def approve_report(report_id:)
    @approved << report_id
    { 'success' => 1 }
  end
end

class UnuAutoapproveTest < Minitest::Test
  def setup
    FileUtils.rm_f(ENV.fetch('TASK_LINKS_FILE', nil))
    @unu = FakeUnu.new
    @sent = []
    @bot = UnuAutoapprove.new(env_path: '/nonexistent', unu: @unu, tg_token: 'tok', admin_ids: [111])
    @bot.define_singleton_method(:notify_admin) { |text| @sent << text }
    @bot.instance_variable_set(:@sent, @sent)
    @bot.define_singleton_method(:log) { |*| }
  end

  def test_approves_only_pending_reports_of_active_tasks
    @unu.tasks = [
      { 'id' => 1, 'status' => 4, 'done_total' => 10, 'limit_total' => 15 },
      { 'id' => 2, 'status' => 4, 'done_total' => 0, 'limit_total' => 10 },
      { 'id' => 3, 'status' => 1, 'done_total' => 0, 'limit_total' => 5 } # новая — не участвует
    ]
    @unu.reports = [
      { 'id' => 101, 'task_id' => 1, 'worker_id' => 7, 'status' => 2 },
      { 'id' => 102, 'task_id' => 1, 'worker_id' => 8, 'status' => 1 }, # в работе
      { 'id' => 103, 'task_id' => 2, 'worker_id' => 9, 'status' => 2 },
      { 'id' => 104, 'task_id' => 3, 'worker_id' => 10, 'status' => 2 } # задача не активна
    ]

    @bot.pass

    assert_equal [101, 103], @unu.approved
  end

  def test_summary_message_with_links_registry
    File.write(ENV.fetch('TASK_LINKS_FILE', nil), JSON.generate('1' => 'https://vk.ru/wall1_2?reply=3'))
    @unu.tasks = [{ 'id' => 1, 'status' => 4, 'done_total' => 12, 'limit_total' => 15 }]
    @unu.reports = [{ 'id' => 101, 'task_id' => 1, 'worker_id' => 7, 'status' => 2 }]

    @bot.pass

    assert_equal 1, @sent.size
    assert_includes @sent.first, 'UNU: аппрув отчётов'
    assert_includes @sent.first, 'https://vk.ru/wall1_2?reply=3 — выполнено 12 из 15'
  end

  def test_summary_falls_back_to_task_id_without_link
    @unu.tasks = [{ 'id' => 5, 'status' => 4, 'done_total' => 1, 'limit_total' => 3 }]
    @unu.reports = [{ 'id' => 105, 'task_id' => 5, 'worker_id' => 7, 'status' => 2 }]

    @bot.pass

    assert_includes @sent.first, 'задача #5 — выполнено 1 из 3'
  end

  def test_no_active_tasks_no_notifications
    @unu.tasks = []
    @bot.pass
    assert_empty @unu.approved
    assert_empty @sent
  end

  def test_no_pending_reports_no_summary
    @unu.tasks = [{ 'id' => 1, 'status' => 4, 'done_total' => 0, 'limit_total' => 5 }]
    @unu.reports = [{ 'id' => 101, 'task_id' => 1, 'worker_id' => 7, 'status' => 1 }]
    @bot.pass
    assert_empty @unu.approved
    assert_empty @sent
  end

  def test_approve_error_notifies_and_continues
    @unu.tasks = [{ 'id' => 1, 'status' => 4, 'done_total' => 0, 'limit_total' => 5 }]
    @unu.reports = [
      { 'id' => 101, 'task_id' => 1, 'worker_id' => 7, 'status' => 2 },
      { 'id' => 102, 'task_id' => 1, 'worker_id' => 8, 'status' => 2 }
    ]
    failing = @unu.method(:approve_report)
    call_count = 0
    @unu.define_singleton_method(:approve_report) do |report_id:|
      call_count += 1
      raise UnuClient::ApiError, 'boom' if call_count == 1

      failing.call(report_id:)
    end

    @bot.pass

    assert_equal [102], @unu.approved
    assert(@sent.any? { |m| m.include?('ошибка аппрува отчёта #101') })
    assert(@sent.any? { |m| m.include?('выполнено') }) # сводка по успешному всё равно ушла
  end
end
