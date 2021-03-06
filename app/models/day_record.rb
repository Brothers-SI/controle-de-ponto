class DayRecord < ActiveRecord::Base
  include AccountManipulable
  extend Enumerize

  enumerize :work_day, in: { yes: 1, no: 0 }, default: :yes
  enumerize :missed_day, in: { yes: 1, no: 0 }, default: :no
  enumerize :medical_certificate, in: { yes: 1, no: 0 }, default: :no

  belongs_to :account
  has_many :time_records, inverse_of: :day_record, dependent: :delete_all, after_remove: :recalculate

  accepts_nested_attributes_for :time_records, reject_if: :all_blank, allow_destroy: true

  validates_presence_of :reference_date
  validates_uniqueness_of :reference_date, scope: :account_id

  validate :future_reference_date

  default_scope -> { order(reference_date: :desc) }

  scope :today, -> { where(reference_date: Date.current) }
  scope :date_range, -> (from, to) { where(reference_date: from..to) }

  after_initialize :set_default_values

  before_save :set_calculated_columns
  after_save :touch_account
  after_save :touch_closure_if_needed

  after_destroy :touch_account

  def total_worked
    @total_worked ||= calculate_total_worked_hours
  end

  def balance
    return @balance if @balance
    @balance = TimeBalance.new

    work_day.yes? ? balance_for_working_day : balance_for_non_working_day

    account_manipulate_balance(@balance)

    @balance
  end

  private

  def balance_for_working_day
    if missed_day.no?
      @balance.calculate_balance(account.workload, total_worked)
    else
      @balance.calculate_balance(account.workload, ZERO_HOUR)
    end
  end

  def balance_for_non_working_day
    if missed_day.no?
      @balance.calculate_balance(ZERO_HOUR, total_worked)
    else
      @balance.reset
    end
  end

  def calculate_total_worked_hours
    return calculated_hours unless reference_date.today? && time_records_odd?

    newest_time = time_records.last

    return ZERO_HOUR if newest_time.nil?

    # sum the difference between last time entry and current time
    # to show up-to-now calculation
    now_diff = Time.diff(newest_time.time, Time.current)
    (calculated_hours + now_diff[:hour].hours) + now_diff[:minute].minutes
  end

  def satisfy_conditions(worked, record_index)
    return true if worked && record_index.odd?
    return true if !worked && record_index.even?
    false
  end

  def future_reference_date
    return unless reference_date
    errors.add(:reference_date, :future_date) if reference_date.future?
  end

  def set_default_values
    self.reference_date ||= Date.current
  end

  def calculate_hours(worked_hours = true)
    total = ZERO_HOUR

    reference_time = time_records.first

    time_records.each_with_index do |time_record, index|
      diff = Time.diff(reference_time.time, time_record.time)
      total = total + diff[:hour].hours + diff[:minute].minutes if satisfy_conditions(worked_hours, index)
      account_manipulate_over_diff(diff, worked_hours, index)
      reference_time = time_record
    end

    total
  end

  def set_calculated_columns
    self.calculated_hours = calculate_hours
    self.time_records_odd = time_records.size.odd?
  end

  def touch_account
    account.touch
  end

  def touch_closure_if_needed
    query = []
    query << '(:date >= start_date  AND :date <= end_date)'
    query << 'start_date = :date OR end_date = :date'
    account.closures.where(query.join(' OR '), date: reference_date).update_all(updated_at: Time.current)
  end

  def recalculate(_)
    set_calculated_columns
    save
  end
end
